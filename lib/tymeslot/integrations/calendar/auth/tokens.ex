defmodule Tymeslot.Integrations.Calendar.Tokens do
  @moduledoc """
  Token refresh utilities for OAuth-based calendar providers.

  Centralizes token expiry checks and refresh flows for Google and Outlook.
  """

  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.TokenUtils
  alias Tymeslot.Integrations.CalendarManagement
  alias Tymeslot.Integrations.Shared.Lock

  require Logger

  @type integration :: map()
  @type user_id :: pos_integer()

  @providers ["google", "outlook"]

  @doc """
  Ensure an integration has a valid access token, refreshing if needed.
  Returns {:ok, updated_integration} or {:error, :token_refresh_failed | :unsupported_provider}.
  """
  @spec ensure_valid_token(integration(), user_id()) :: {:ok, integration()} | {:error, term()}
  def ensure_valid_token(integration, _user_id) do
    if TokenUtils.token_expired?(integration) do
      refresh_oauth_token(integration)
    else
      {:ok, integration}
    end
  end

  @doc """
  Refresh the access token for an integration.
  Persists refreshed credentials when possible.

  When the stored credentials no longer decrypt, the integration is flagged
  for reconnection and the answer is `{:error, :requires_reencryption}`, or
  `{:error, :reauth_flag_failed}` when the flag could not be written.
  """
  @spec refresh_oauth_token(integration()) :: {:ok, integration()} | {:error, term()}
  def refresh_oauth_token(%{provider: provider} = integration)
      when provider in @providers do
    integration_id = Map.get(integration, :id) || Map.get(integration, "id") || :unknown

    if integration_id == :unknown do
      perform_refresh(integration)
    else
      # Ensure integration_id is an integer if it's a string
      integration_id =
        case integration_id do
          id when is_integer(id) ->
            id

          id when is_binary(id) ->
            case Integer.parse(id) do
              {int, ""} -> int
              _other -> :unknown
            end

          _other ->
            :unknown
        end

      if integration_id == :unknown do
        perform_refresh(integration)
      else
        Lock.with_lock(refresh_lock_key(integration_id), fn ->
          refresh_under_lock(integration, integration_id)
        end)
      end
    end
  end

  def refresh_oauth_token(_integration), do: {:error, :unsupported_provider}

  @doc """
  The lock every refresh of a calendar integration's OAuth token takes,
  whichever path starts it (the hourly refresh job, a connection test, or a
  provider API call finding its token expired). One key is what makes the
  refresh single-flight: two keys would let two paths POST the same refresh
  token at once, and with a provider that rotates refresh tokens the later
  write could keep the older one.
  """
  @spec refresh_lock_key(term()) :: {:calendar_token_refresh, term()}
  def refresh_lock_key(integration_id), do: {:calendar_token_refresh, integration_id}

  @doc """
  The attributes to write after a successful refresh: the new tokens, and a
  cleared `sync_error` unless the integration is flagged for reconnection.
  """
  @spec refreshed_token_attrs(integration(), String.t(), String.t() | nil, DateTime.t()) ::
          map()
  def refreshed_token_attrs(integration, access, refresh, expires_at) do
    maybe_clear_sync_error(
      %{access_token: access, refresh_token: refresh, token_expires_at: expires_at},
      integration
    )
  end

  # Re-fetch from DB to ensure we have the most up-to-date tokens
  # (in case another process just refreshed them while we were waiting for the lock)
  defp refresh_under_lock(integration, integration_id) do
    case CalendarIntegrationQueries.get(integration_id) do
      {:ok, fresh_integration} -> refresh_if_expired(fresh_integration)
      {:error, :requires_reencryption, stale} -> flag_unreadable(stale)
      _error -> refresh_if_expired(integration)
    end
  end

  # `handle_reauth_required/1` answers in Oban's terms; this function's
  # callers expect `{:ok, _} | {:error, _}`.
  defp flag_unreadable(stale) do
    case CalendarManagement.handle_reauth_required(stale) do
      {:discard, _reason} -> {:error, :requires_reencryption}
      {:error, _reason} -> {:error, :reauth_flag_failed}
    end
  end

  defp refresh_if_expired(integration) do
    if TokenUtils.token_expired?(integration) do
      perform_refresh(integration)
    else
      {:ok, integration}
    end
  end

  defp perform_refresh(%{provider: "google"} = integration) do
    case Config.google_calendar_api_module().refresh_token(integration) do
      {:ok, {new_access_token, new_refresh_token, expires_at}} ->
        # Use new refresh token if provided (rotation), else keep old one
        refresh_to_persist =
          if is_binary(new_refresh_token) and new_refresh_token != "",
            do: new_refresh_token,
            else: Map.get(integration, :refresh_token)

        persist_and_return(
          integration,
          new_access_token,
          refresh_to_persist,
          expires_at
        )

      {:error, type, msg} ->
        {:error, {type, msg}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp perform_refresh(%{provider: "outlook"} = integration) do
    case Config.outlook_calendar_api_module().refresh_token(integration) do
      {:ok, {new_access_token, new_refresh_token, expires_at}} ->
        persist_and_return(integration, new_access_token, new_refresh_token, expires_at)

      {:error, type, msg} ->
        {:error, {type, msg}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Best-effort persistence: if we have a schema struct, write to DB; otherwise
  # return the updated map.
  defp persist_and_return(%CalendarIntegrationSchema{} = integration, access, refresh, expires_at) do
    attrs = refreshed_token_attrs(integration, access, refresh, expires_at)

    case CalendarIntegrationQueries.update(integration, attrs) do
      {:ok, updated} ->
        {:ok, CalendarIntegrationSchema.decrypt_oauth_tokens(updated)}

      {:error, changeset} ->
        Logger.error("Failed to persist refreshed OAuth tokens",
          integration_id: integration.id,
          error: LogFormat.reason(changeset.errors)
        )

        {:error, :token_persistence_failed}
    end
  end

  defp persist_and_return(integration, access, refresh, expires_at) when is_map(integration) do
    {:ok,
     Map.merge(integration, %{
       access_token: access,
       refresh_token: refresh,
       token_expires_at: expires_at
     })}
  end

  # A successful refresh only means the token is valid again; it says nothing
  # about whatever flagged the integration for reauth in the first place (a
  # deleted booking calendar, no calendar selected). Clearing `sync_error`
  # here while `needs_reauth` is still true would erase the reason the
  # dashboard notice and reauth email depend on.
  defp maybe_clear_sync_error(attrs, %{needs_reauth: true}), do: attrs
  defp maybe_clear_sync_error(attrs, _integration), do: Map.put(attrs, :sync_error, nil)
end
