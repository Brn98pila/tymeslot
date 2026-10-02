defmodule Tymeslot.Integrations.Calendar.AccountCleanup do
  @moduledoc """
  Tells Google and Microsoft to stop working for an account that is being
  deleted, for every calendar it connected:

    * Google: stops the push channel, then revokes the OAuth grant.
    * Outlook: deletes the Graph change-notification subscription. Microsoft
      offers no practical per-token revoke for this flow; the grant becomes
      unusable once the stored refresh token is deleted with the account.

  Calendar events are not touched: a meeting the deletion removes from
  Tymeslot may still take place between host and guest, so the host's
  events stay where they are.

  Every step is best-effort: a failure is logged and the next step runs.
  Must run before the account row is deleted, which cascades the
  credentials away.
  """

  require Logger

  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.Google.CalendarAPI, as: GoogleAPI
  alias Tymeslot.Integrations.Calendar.Outlook.CalendarAPI, as: OutlookAPI
  alias Tymeslot.Integrations.Calendar.Shared.AccessToken
  alias Tymeslot.Integrations.Google.TokenRevocation

  @spec run(pos_integer()) :: :ok
  def run(user_id) do
    user_id
    |> CalendarIntegrationQueries.list_all_for_user()
    |> Enum.each(&clean_up/1)
  end

  defp clean_up(%CalendarIntegrationSchema{provider: "google"} = integration) do
    integration |> stop_push_channel() |> log_outcome(integration, :stop_push_channel)
    integration |> revoke_grant() |> log_outcome(integration, :revoke_grant)
  end

  defp clean_up(%CalendarIntegrationSchema{provider: "outlook"} = integration) do
    integration
    |> delete_graph_subscription()
    |> log_outcome(integration, :delete_graph_subscription)
  end

  defp clean_up(_integration), do: :ok

  defp stop_push_channel(
         %{google_channel_id: channel_id, google_channel_resource_id: resource_id} = integration
       )
       when is_binary(channel_id) and is_binary(resource_id) do
    body = %{"id" => channel_id, "resourceId" => resource_id}

    integration
    |> AccessToken.with_access_token(&GoogleAPI.refresh_token/1, fn token ->
      GoogleAPI.make_request_with_body(:post, "/channels/stop", token, body)
    end)
    |> gone_counts_as_done()
  end

  defp stop_push_channel(_integration), do: :skipped

  defp delete_graph_subscription(%{graph_subscription_id: subscription_id} = integration)
       when is_binary(subscription_id) do
    path = "/subscriptions/#{URI.encode(subscription_id)}"

    integration
    |> AccessToken.with_access_token(&OutlookAPI.refresh_token/1, fn token ->
      OutlookAPI.make_request(:delete, path, token, %{})
    end)
    |> gone_counts_as_done()
  end

  defp delete_graph_subscription(_integration), do: :skipped

  defp revoke_grant(integration),
    do: TokenRevocation.revoke(integration.refresh_token || integration.access_token)

  # A channel or subscription the provider no longer has is already stopped.
  defp gone_counts_as_done({:ok, _body}), do: :ok
  defp gone_counts_as_done({:error, kind, _message}) when kind in [:not_found, :gone], do: :ok
  defp gone_counts_as_done(other), do: other

  defp log_outcome(outcome, _integration, _step) when outcome in [:ok, :skipped], do: :ok

  defp log_outcome(failure, integration, step) do
    Logger.warning("Account deletion: calendar cleanup step failed; carrying on",
      step: step,
      integration_id: integration.id,
      user_id: integration.user_id,
      reason: LogFormat.reason(failure)
    )

    :ok
  end
end
