defmodule Tymeslot.Integrations.Common.OAuth.Token do
  @moduledoc """
  Common helpers for validating and refreshing OAuth access tokens.

  This module centralizes token validity checks and the pattern for ensuring
  a usable access token, reducing duplication across provider clients.
  """

  require Logger

  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.Tokens
  alias Tymeslot.Integrations.CalendarManagement
  alias Tymeslot.Integrations.Shared.OAuth.Refresh

  @default_lock_timeout_ms 60_000

  @type integration :: map()
  @type decrypt_fun :: (integration() -> integration())
  @type refresh_fun :: (integration() ->
                          {:ok, {String.t(), String.t(), DateTime.t()}}
                          | {:error, any()}
                          | {:error, atom(), any()})

  @doc """
  Returns true if the integration token is valid with a buffer (in seconds).

  Defaults to a 5 minute (300s) buffer to proactively refresh tokens. See
  `Tymeslot.Integrations.Shared.OAuth.Refresh.valid?/2`.
  """
  @spec valid?(integration(), non_neg_integer()) :: boolean()
  def valid?(integration, buffer_seconds \\ 300),
    do: Refresh.valid?(Map.get(integration, :token_expires_at), buffer_seconds)

  @doc """
  Ensures a valid access token is available for the given integration.

  Options:
    - :decrypt_fun - function to decrypt tokens on the integration (default: identity)
    - :refresh_fun - REQUIRED function to refresh tokens, returns {:ok, {access, refresh, expires_at}} or {:error, ...}
    - :buffer_seconds - seconds before expiry to consider invalid (default: 300)
    - :persist - when true (default), persist refreshed tokens to storage when possible
    - :refetch_fun - re-reads the integration by id under the lock
    - :lock_timeout - how long to wait for the refresh lock (default: 60s)

  Returns {:ok, access_token} or {:error, reason}.
  """
  @spec ensure_valid_access_token(integration(), keyword()) :: {:ok, String.t()} | {:error, any()}
  def ensure_valid_access_token(integration, opts) when is_map(integration) and is_list(opts) do
    decrypt_fun = Keyword.get(opts, :decrypt_fun, &Function.identity/1)
    buffer_seconds = Keyword.get(opts, :buffer_seconds, 300)

    if valid?(integration, buffer_seconds) do
      {:ok, access_token(decrypt_fun.(integration))}
    else
      refresh(integration, decrypt_fun, buffer_seconds, opts)
    end
  end

  # A stale token is refreshed from the row re-read under the lock, not the
  # caller's copy: a long job's copy can predate a reconnect flag, and the
  # attributes written after the refresh depend on that flag.
  defp refresh(integration, decrypt_fun, buffer_seconds, opts) do
    integration_id = Map.get(integration, :id) || Map.get(integration, "id") || :no_id
    refresh_fun = Keyword.fetch!(opts, :refresh_fun)
    refetch_fun = Keyword.get(opts, :refetch_fun)
    persist? = Keyword.get(opts, :persist, true)

    Refresh.run(
      Tokens.refresh_lock_key(integration_id),
      %{
        fetch: fn -> {:ok, refetch(integration, refetch_fun, integration_id)} end,
        already_valid: &{:ok, access_token(decrypt_fun.(&1))},
        refresh: &refresh_fun.(&1),
        persist: &handle_refresh_result({:ok, &2}, &1, persist?)
      },
      buffer_seconds: buffer_seconds,
      lock_timeout: Keyword.get(opts, :lock_timeout, @default_lock_timeout_ms)
    )
  end

  defp refetch(integration, nil, _id), do: integration

  defp refetch(integration, refetch_fun, id) do
    case refetch_fun.(id) do
      %{} = fresh -> fresh
      _missing -> integration
    end
  end

  defp access_token(decrypted),
    do: Map.get(decrypted, :access_token) || Map.get(decrypted, "access_token")

  defp handle_refresh_result(result, integration, persist?) do
    case result do
      {:ok, access_token} when is_binary(access_token) ->
        # A refresh function that hands back a bare token has nothing to persist
        {:ok, access_token}

      {:ok, {access_token, refresh_token, expires_at}} ->
        if persist? do
          case persist_tokens(integration, access_token, refresh_token, expires_at) do
            :ok ->
              {:ok, access_token}

            {:error, reason} ->
              # Returning the fresh access_token here would mask the fact that
              # the DB still holds the old one — subsequent callers would read
              # stale tokens, re-refresh each time, and risk IdP rate-limits or
              # refresh-token revocation (Google's one-use policy). Surface the
              # failure so callers can fail loudly instead.
              Logger.warning("OAuth token persistence failed",
                integration_id: Map.get(integration, :id),
                reason: LogFormat.reason(reason)
              )

              {:error, :token_persist_failed}
          end
        else
          {:ok, access_token}
        end

      {:ok, _non_binary_token} ->
        {:error, :token_not_available}

      {:error, type, reason} ->
        {:error, type, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Persists refreshed tokens to the integration row. Returns `:ok` on success
  # and `{:error, reason}` on failure so the caller can surface the error
  # rather than silently serving stale DB state on the next call.
  @spec persist_tokens(map(), String.t(), String.t(), DateTime.t()) :: :ok | {:error, term()}
  defp persist_tokens(%CalendarIntegrationSchema{} = integration, access, refresh, expires_at) do
    attrs = Tokens.refreshed_token_attrs(integration, access, refresh, expires_at)

    case CalendarIntegrationQueries.update(integration, attrs) do
      {:ok, _updated_integration} -> :ok
      {:error, update_error} -> {:error, update_error}
    end
  end

  defp persist_tokens(%{id: id}, access, refresh, expires_at) when is_integer(id) do
    case CalendarIntegrationQueries.get(id) do
      {:ok, %CalendarIntegrationSchema{} = integ} ->
        persist_tokens(integ, access, refresh, expires_at)

      {:error, :requires_reencryption, integration} ->
        CalendarManagement.handle_reauth_required(integration)
        {:error, :requires_reencryption}

      {:error, fetch_error} ->
        {:error, fetch_error}
    end
  end

  defp persist_tokens(_integration, _access, _refresh, _expires_at), do: :ok
end
