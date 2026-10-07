defmodule Tymeslot.Integrations.Video.OAuthTokenManager do
  @moduledoc """
  Shared OAuth token-refresh orchestration for video providers.

  Every video provider (Zoom, Teams, Google Meet) carries the same
  double-checked, locked token-refresh state machine:

    1. If we lack an `integration_id`/`user_id`, refresh directly (no lock,
       no DB re-fetch) — there is nothing to coordinate against.
    2. Otherwise acquire a blocking per-integration lock, re-fetch the
       integration from the database, and decrypt its credentials.
    3. If the freshly-read token still has more than the buffer window of
       life left, another process already refreshed it — return that token
       without hitting the OAuth endpoint.
    4. Otherwise (token still expiring, or the integration vanished),
       perform the actual OAuth refresh, with the credentials just read.

  Providers differ only in their **return shape**, captured by callbacks.
  Zoom and Teams return a bare access-token string; Google Meet returns a
  config map merged with the refreshed credentials.

    * `:refresh` performs the OAuth call, persists, and shapes the return
      value for the in-lock refresh paths (token expiring, or integration
      vanished).
    * `:already_refreshed` builds the return value when another process
      already refreshed the token, from the freshly decrypted integration.
    * `:fallback_refresh` (optional) handles the no-`integration_id`/no-
      `user_id` path where there is nothing to lock or re-fetch against.
      Defaults to `:refresh`. Teams is the one provider whose fallback
      return shape (the full refreshed-token map) differs from its in-lock
      shape (the bare access token), so it supplies its own.

  The expiry buffer and the lock are those of
  `Tymeslot.Integrations.Shared.OAuth.Refresh`, the refresh flow calendar
  integrations share.

  ## Beyond the lock

  Two further steps sit either side of the locked refresh and were, until
  they moved here, reimplemented per provider:

    * `validated_access_token/2` — ask the provider's OAuth helper whether the
      stored token is still good, and refresh when it is not.
    * `persist_tokens/3` — write refreshed credentials back to the integration
      row, tolerating an integration that vanished mid-refresh.

  Marking the integration "Reconnect required" after a 401 that survived a
  forced refresh is not OAuth-specific, so it lives in
  `Tymeslot.Integrations.Video.NeedsReauth`.

  Each provider still owns what genuinely differs: which OAuth helper to call,
  which scope to request, and which attributes a refresh response maps to.
  Zoom rotates its refresh token on every call and must not clobber the stored
  one with a blank; Teams falls back to the access token; Google Meet writes
  all four fields unconditionally. Those rules stay in the providers.
  """

  require Logger

  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Integrations.Shared.OAuth.Refresh
  alias Tymeslot.Integrations.Video
  alias Tymeslot.Integrations.Video.VideoIntegrationQueries
  alias Tymeslot.Integrations.Video.VideoIntegrationSchema

  @type config :: map()
  @type decrypted :: map()
  @type result :: {:ok, term()} | {:error, term()}

  @typedoc """
  Provider-specific hooks plugged into the shared flow.

    * `:provider` — the provider (`:zoom`, `:teams`, `:google_meet`).
    * `:refresh` — performs the OAuth refresh, persistence, and return
      shaping for the in-lock paths. Receives the original config.
    * `:already_refreshed` — builds the return value when another process
      already refreshed the token. Receives the original config and the
      freshly decrypted integration credentials.
    * `:fallback_refresh` (optional) — return shaping for the unlocked
      no-ids path; defaults to `:refresh`.
  """
  @type hooks :: %{
          required(:provider) => atom(),
          required(:refresh) => (config() -> result()),
          required(:already_refreshed) => (config(), decrypted() -> result()),
          optional(:fallback_refresh) => (config() -> result())
        }

  @doc """
  Returns whether `expires_at` is further out than the refresh buffer.

  `nil` (no known expiry) is treated as "not valid" so a refresh is forced.
  The rule is `Tymeslot.Integrations.Shared.OAuth.Refresh.valid?/2`, shared
  with calendar integrations.
  """
  @spec token_still_valid?(DateTime.t() | nil) :: boolean()
  def token_still_valid?(expires_at), do: Refresh.valid?(expires_at)

  @doc """
  Runs the shared locked, double-checked token-refresh flow.

  See the module docs for the full state machine. Returns whatever the
  provider's `:refresh`/`:already_refreshed` hooks return.

  ## Options

    * `:force` (default `false`) — bypass the validity double-check and always
      run the provider's `:refresh` hook, still under the per-integration lock.
      Use this on a post-401 path: the access token was *server-side* rejected,
      so the DB expiry buffer can't be trusted and an `:already_refreshed`
      short-circuit would just replay the same rejected token.
  """
  @spec refresh_with_lock(config(), hooks(), keyword()) :: result()
  def refresh_with_lock(config, hooks, opts \\ []) do
    integration_id = Map.get(config, :integration_id)
    user_id = Map.get(config, :user_id)
    force? = Keyword.get(opts, :force, false)

    if is_nil(integration_id) or is_nil(user_id) do
      fallback = Map.get(hooks, :fallback_refresh, hooks.refresh)
      fallback.(config)
    else
      Refresh.run(Refresh.lock_key(:video, integration_id), %{
        fetch: fn -> {:ok, fetch_current(integration_id, user_id)} end,
        valid?: &still_good?(&1, config, force?),
        already_valid: fn {:found, fresh_integration, decrypted} ->
          hooks.already_refreshed.(config, build_decrypted(fresh_integration, decrypted))
        end,
        # The provider's hook persists by itself, so there is no `:persist`.
        refresh: &hooks.refresh.(refresh_config(&1, config))
      })
    end
  end

  defp fetch_current(integration_id, user_id) do
    case Video.fetch_integration_for_user(integration_id, user_id) do
      {:ok, fresh_integration} ->
        {:found, fresh_integration, VideoIntegrationSchema.decrypt_credentials(fresh_integration)}

      {:error, :not_found} ->
        :missing
    end
  end

  # Forced path: the caller proved the access token is rejected server-side,
  # so the expiry cannot be trusted. Only a sibling having rotated the token
  # already (the stored access token differs from the one that drew the 401)
  # makes another OAuth round-trip unnecessary.
  defp still_good?(:missing, _config, _force?), do: false

  defp still_good?({:found, _integration, decrypted}, config, true),
    do: decrypted.access_token != Map.get(config, :access_token)

  defp still_good?({:found, _integration, decrypted}, _config, false),
    do: token_still_valid?(decrypted.token_expires_at)

  # The refresh runs with the credentials just read under the lock, never the
  # caller's copy: Zoom and Microsoft rotate the refresh token, so a copy taken
  # before a sibling's refresh holds one the provider has already retired.
  defp refresh_config(:missing, config), do: config

  defp refresh_config({:found, _integration, decrypted}, config) do
    Map.merge(config, %{
      access_token: decrypted.access_token,
      refresh_token: decrypted.refresh_token
    })
  end

  # Surfaces the integration's `oauth_scope` alongside the decrypted
  # credentials so providers that fold scope into their return value
  # (Google Meet) have it available without re-reading the integration.
  defp build_decrypted(fresh_integration, decrypted) do
    Map.put(decrypted, :oauth_scope, fresh_integration.oauth_scope)
  end

  @doc """
  Returns a usable access token, refreshing when the provider says to.

  Delegates the "is this token still good?" question to the provider's own
  OAuth helper, because each provider answers it differently (Zoom and Teams
  both probe the token; Google Meet compares the stored expiry directly and so
  does not use this function).

  ## Options

    * `:oauth_helper` — the module exposing `validate_token/1`. **Required.**
    * `:label` — provider name used in log lines, e.g. `"Zoom"`. **Required.**
    * `:on_refresh` — a `(config -> result)` invoked when the helper reports
      `:needs_refresh`. **Required.**
  """
  @spec validated_access_token(config(), keyword()) :: result()
  def validated_access_token(config, opts) do
    oauth_helper = Keyword.fetch!(opts, :oauth_helper)
    label = Keyword.fetch!(opts, :label)
    on_refresh = Keyword.fetch!(opts, :on_refresh)

    case oauth_helper.validate_token(config) do
      {:ok, :valid} ->
        {:ok, Map.get(config, :access_token)}

      {:ok, :needs_refresh} ->
        on_refresh.(config)

      {:error, reason} ->
        Logger.error("Video OAuth token validation failed",
          provider: label,
          reason: LogFormat.reason(reason)
        )

        {:error, "Token validation failed: #{reason}"}
    end
  end

  @doc """
  Writes refreshed credentials back to the integration row.

  `attrs` is the provider's own mapping of its refresh response onto schema
  fields, because that mapping is the one part of persistence that genuinely
  differs between providers.

  An integration that disappeared between the refresh and this write is not an
  error: the refresh still succeeded, and there is simply nothing left to
  update. That case logs a warning and returns `:ok`.
  """
  @spec persist_tokens(config(), map(), String.t()) :: :ok | {:error, term()}
  def persist_tokens(config, attrs, label) do
    integration_id = Map.get(config, :integration_id)
    user_id = Map.get(config, :user_id)

    case Video.fetch_integration_for_user(integration_id, user_id) do
      {:ok, integration} ->
        write_tokens(integration, attrs, integration_id, label)

      {:error, :not_found} ->
        Logger.warning("Video integration vanished before token update",
          provider: label,
          integration_id: integration_id
        )

        :ok
    end
  end

  defp write_tokens(integration, attrs, integration_id, label) do
    case VideoIntegrationQueries.update(integration, attrs) do
      {:ok, _updated} ->
        Logger.info("Updated video OAuth tokens",
          provider: label,
          integration_id: integration_id
        )

        :ok

      {:error, reason} ->
        Logger.error("Failed to persist video OAuth tokens",
          provider: label,
          integration_id: integration_id,
          reason: LogFormat.reason(reason)
        )

        {:error, reason}
    end
  end
end
