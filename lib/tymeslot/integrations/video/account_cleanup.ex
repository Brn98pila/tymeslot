defmodule Tymeslot.Integrations.Video.AccountCleanup do
  @moduledoc """
  Revokes the OAuth grants an account being deleted gave its video
  providers: Google Meet through Google's revoke endpoint, Zoom through
  Zoom's. Microsoft Teams has no practical per-token revoke, and MiroTalk or
  a custom link holds no grant, so those are left alone.

  Rooms are not deleted: a guest may still join a meeting that the deletion
  removes from Tymeslot, and deleting the room would break their link.

  Best-effort: a failure, including a raise or exit while cleaning one
  integration (a database error, a lock timeout, the HTTP client), is logged
  and the next integration is tried. Must
  run before the account row is deleted, which cascades the credentials away.
  """

  require Logger

  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Integrations.Shared.OAuth.GoogleTokenRevocation
  alias Tymeslot.Integrations.Video.AccessToken
  alias Tymeslot.Integrations.Video.VideoIntegrationQueries
  alias Tymeslot.Integrations.Video.Zoom.ZoomOAuthHelper

  @spec run(pos_integer()) :: :ok
  def run(user_id) do
    user_id
    |> VideoIntegrationQueries.list_all_for_user()
    |> Enum.each(&clean_up_independently/1)
  end

  defp clean_up_independently(integration) do
    clean_up(integration)
  rescue
    exception -> log_outcome({:error, exception}, integration)
  catch
    kind, reason -> log_outcome({:error, {kind, reason}}, integration)
  end

  defp clean_up(%{provider: "google_meet"} = integration) do
    (integration.refresh_token || integration.access_token)
    |> GoogleTokenRevocation.revoke()
    |> log_outcome(integration)
  end

  # Zoom revokes by access token, so an expired one is refreshed first,
  # through the provider, which takes the refresh lock and stores the result.
  defp clean_up(%{provider: "zoom"} = integration) do
    with {:ok, token} <- AccessToken.fetch(integration.id, integration.user_id) do
      ZoomOAuthHelper.revoke_token(token)
    end
    |> log_outcome(integration)
  end

  defp clean_up(_integration), do: :ok

  defp log_outcome(:ok, _integration), do: :ok

  defp log_outcome(failure, integration) do
    Logger.warning("Account deletion: video grant revocation failed; carrying on",
      provider: integration.provider,
      integration_id: integration.id,
      user_id: integration.user_id,
      reason: LogFormat.reason(failure)
    )

    :ok
  end
end
