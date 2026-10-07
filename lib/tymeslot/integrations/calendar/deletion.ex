defmodule Tymeslot.Integrations.Calendar.Deletion do
  @moduledoc """
  Business logic for deleting an integration while maintaining the primary
  calendar invariant (promote another or clear primary).
  """

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationWebhookQueries
  alias Tymeslot.Integrations.Calendar.Google.PushChannel
  alias Tymeslot.Integrations.Calendar.Outlook.GraphSubscription
  alias Tymeslot.Integrations.Calendar.PrimaryElection
  alias Tymeslot.Integrations.CalendarManagement
  alias Tymeslot.MeetingTypes.MeetingTypeQueries
  alias Tymeslot.Profiles.ProfileQueries
  alias Tymeslot.Repo

  @type user_id :: pos_integer()

  @doc """
  Delete an integration. If it is the primary one, promote another if available,
  otherwise clear primary.

  Returns:
    {:ok, :deleted}
    {:ok, {:deleted_promoted, promoted_id}}
    {:ok, {:deleted_cleared_primary}}
    {:error, :not_found | term()}
  """
  @spec delete_with_primary_reassignment(user_id(), pos_integer()) ::
          {:ok, :deleted | {:deleted_promoted, pos_integer()} | {:deleted_cleared_primary}}
          | {:error, term()}
  def delete_with_primary_reassignment(user_id, integration_id)
      when is_integer(user_id) and is_integer(integration_id) do
    with {:ok, integration} <-
           CalendarManagement.get_calendar_integration(integration_id, user_id),
         :ok <- stop_push_notifications(integration),
         {:ok, promoted_result} <- delete_and_reassign(integration) do
      case promoted_result do
        {:promoted, next_id} -> {:ok, {:deleted_promoted, next_id}}
        :cleared -> {:ok, {:deleted_cleared_primary}}
        :unchanged -> {:ok, :deleted}
      end
    else
      {:error, :not_found} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  # Before the delete, while the row still holds the tokens a refresh would
  # write back. Best-effort: a channel or subscription left running expires
  # on its own.
  defp stop_push_notifications(%{provider: "google"} = integration),
    do: PushChannel.stop_push_channel(integration)

  defp stop_push_notifications(%{provider: "outlook"} = integration),
    do: GraphSubscription.unregister(integration)

  defp stop_push_notifications(_integration), do: :ok

  # The promotion and the delete commit together, under the lock a toggle or
  # an automatic pause takes too, so a failed delete leaves the primary where
  # it was and a concurrent change cannot elect from a list this one is
  # changing.
  defp delete_and_reassign(integration) do
    Repo.transaction(fn ->
      CalendarIntegrationWebhookQueries.lock_user_profile_and_integrations(integration.user_id)
      promoted_result = maybe_handle_primary(integration)
      MeetingTypeQueries.clear_calendar_references(integration.id)

      case CalendarManagement.delete_calendar_integration(integration) do
        {:ok, _result} -> promoted_result
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  # Decided on the stored primary id rather than a decrypted row, so an
  # unreadable primary that is deleted still hands the role on.
  defp maybe_handle_primary(%{id: id, user_id: user_id}) do
    case ProfileQueries.get_by_user_id(user_id) do
      {:ok, %{primary_calendar_integration_id: ^id}} -> PrimaryElection.elect_next(user_id, [id])
      _not_primary -> :unchanged
    end
  end
end
