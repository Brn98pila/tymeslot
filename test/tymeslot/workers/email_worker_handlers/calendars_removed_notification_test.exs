defmodule Tymeslot.Workers.EmailWorkerHandlers.CalendarsRemovedNotificationTest do
  @moduledoc """
  The email job telling an owner that their calendar server stopped listing
  calendars Tymeslot used.
  """
  use Tymeslot.DataCase, async: true

  @moduletag :workers
  @moduletag :calendar

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.EmailServiceMock
  alias Tymeslot.Workers.EmailWorkerHandlers
  alias Tymeslot.Workers.EmailWorkerHandlers.IntegrationEmails

  setup :verify_on_exit!

  describe "handle_calendars_removed_notification/1" do
    test "sends the owner the calendars named in the job" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      expect(EmailServiceMock, :send_calendars_removed_notification, fn sent_user,
                                                                        sent_integration,
                                                                        names ->
        assert sent_user.id == user.id
        assert sent_integration.id == integration.id
        assert names == ["Work", "Team"]
        {:ok, "sent"}
      end)

      assert :ok =
               execute_calendars_removed_notification(user.id, integration.id, ["Work", "Team"])
    end

    test "discards, as expected, when the integration was deleted before the job ran" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)
      Repo.delete!(integration)

      expect(EmailServiceMock, :send_calendars_removed_notification, 0, fn _user, _int, _names ->
        {:ok, "sent"}
      end)

      assert {:discard, reason} =
               execute_calendars_removed_notification(user.id, integration.id, ["Work"])

      assert IntegrationEmails.expected_discard?(reason)
    end
  end

  defp execute_calendars_removed_notification(user_id, integration_id, names) do
    EmailWorkerHandlers.execute_email_action("send_calendars_removed_notification", %{
      "user_id" => user_id,
      "integration_id" => integration_id,
      "calendar_names" => names
    })
  end
end
