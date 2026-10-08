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

  Every step is best-effort: a failure is logged and the next step runs. Each
  integration is independent: credentials are decrypted per integration, and
  a raise or exit while cleaning one (an undecryptable row, a database error,
  a lock timeout) is logged without stopping the others. Must run before the
  account row is deleted, which cascades the credentials away.
  """

  require Logger

  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.Google.PushChannel
  alias Tymeslot.Integrations.Calendar.Outlook.GraphSubscription
  alias Tymeslot.Integrations.Shared.OAuth.GoogleTokenRevocation

  @spec run(pos_integer()) :: :ok
  def run(user_id) do
    user_id
    |> CalendarIntegrationQueries.list_all_for_user_encrypted()
    |> Enum.each(&clean_up_independently/1)
  end

  defp clean_up_independently(integration) do
    integration
    |> CalendarIntegrationSchema.decrypt_credentials()
    |> clean_up()
  rescue
    exception -> log_outcome({:error, exception}, integration, :clean_up)
  catch
    kind, reason -> log_outcome({:error, {kind, reason}}, integration, :clean_up)
  end

  # Stopping the channel and deleting the subscription always answer `:ok`
  # and log their own failures; each step is still isolated, so a raise in
  # one does not skip the next.
  defp clean_up(%CalendarIntegrationSchema{provider: "google"} = integration) do
    step(integration, :stop_push_channel, fn -> PushChannel.stop_push_channel(integration) end)
    step(integration, :revoke_grant, fn -> revoke_grant(integration) end)
  end

  defp clean_up(%CalendarIntegrationSchema{provider: "outlook"} = integration),
    do:
      step(integration, :delete_graph_subscription, fn ->
        GraphSubscription.unregister(integration)
      end)

  defp clean_up(_integration), do: :ok

  defp step(integration, name, fun) do
    fun.() |> log_outcome(integration, name)
  rescue
    exception -> log_outcome({:error, exception}, integration, name)
  catch
    kind, reason -> log_outcome({:error, {kind, reason}}, integration, name)
  end

  defp revoke_grant(integration),
    do: GoogleTokenRevocation.revoke(integration.refresh_token || integration.access_token)

  defp log_outcome(:ok, _integration, _step), do: :ok

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
