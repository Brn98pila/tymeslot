defmodule Tymeslot.Bookings.BestEffortFanOutTest do
  @moduledoc """
  A booking's integration fan-out (webhooks, Telegram, Slack) runs after the
  booking commits, so a failure in it cannot cost the booking, and a booking
  that never commits sends none of it.

  The fan-out used to run inside the booking transaction, rescued as
  best-effort. A database error inside it still left the transaction unable
  to commit, so the booking was lost over a chat notification. Here the
  database fails the Slack step two ways: its read of the host's
  integrations finds the table gone (renamed inside this test's sandbox
  transaction, restored when that rolls back), or its job insert is refused
  by a trigger.

  Synchronous: both are DDL, and the Slack switch is application config.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :bookings
  @moduletag :notifications
  @moduletag :integration

  import Tymeslot.AvailabilityTestHelpers
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory
  import Tymeslot.MeetingTestHelpers

  alias ErrorTracker.Error
  alias Tymeslot.Bookings.Activation
  alias Tymeslot.Bookings.Create
  alias Tymeslot.Bookings.CreateAdHoc
  alias Tymeslot.Meetings.Approval
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.EmailWorker
  alias Tymeslot.Workers.SlackWorker

  setup do
    previous = Application.get_env(:tymeslot, :slack_notifications_allowed)
    Application.put_env(:tymeslot, :slack_notifications_allowed, true)
    on_exit(fn -> Application.put_env(:tymeslot, :slack_notifications_allowed, previous) end)

    TestMocks.setup_all_mocks()

    %{user: user} = create_always_bookable_profile(timezone: "America/New_York")
    insert(:slack_integration, user: user, events: ["meeting.created", "meeting.requested"])

    %{user: user}
  end

  describe "a failure in the fan-out after commit" do
    test "a Slack read the database fails does not cost the booking", %{user: user} do
      with_config(:error_tracker, enabled: true)
      Repo.query!("ALTER TABLE slack_integrations RENAME TO slack_integrations_hidden")

      assert {:ok, %MeetingSchema{} = meeting} =
               Create.execute(build_meeting_params(user), build_form_data())

      assert_booking_stands(meeting)
      assert reported?("Elixir.Postgrex.Error")
    end

    test "a Slack job the database refuses does not cost the booking", %{user: user} do
      refuse_slack_jobs!()

      assert {:ok, %MeetingSchema{} = meeting} =
               Create.execute(build_meeting_params(user), build_form_data())

      assert_booking_stands(meeting)
      refute_enqueued(worker: SlackWorker)
    end
  end

  describe "a host's own booking from the dashboard" do
    test "a Slack read the database fails does not cost the booking", %{user: user} do
      Repo.query!("ALTER TABLE slack_integrations RENAME TO slack_integrations_hidden")
      start_time = DateTime.utc_now() |> DateTime.add(2, :day) |> DateTime.truncate(:second)

      assert {:ok, %MeetingSchema{} = meeting} =
               CreateAdHoc.execute(%{
                 title: "Quick sync",
                 start_time: start_time,
                 end_time: DateTime.add(start_time, 1, :hour),
                 attendee_name: "Jane Doe",
                 attendee_email: "jane@example.com",
                 attendee_timezone: "Europe/Berlin",
                 organizer_user_id: user.id,
                 calendar_integration_id: nil,
                 calendar_path: nil,
                 video_integration_id: nil
               })

      assert_booking_stands(meeting)
    end
  end

  describe "the fan-out runs once, and only for a booking that commits" do
    test "a committed booking sends one Slack notice", %{user: user} do
      assert {:ok, meeting} = Create.execute(build_meeting_params(user), build_form_data())

      assert [_one] = all_enqueued(worker: SlackWorker, args: %{"meeting_id" => meeting.id})
    end

    test "a booking that loses its slot sends none", %{user: user} do
      params = build_meeting_params(user)
      assert {:ok, winner} = Create.execute(params, build_form_data())

      assert {:error, :slot_taken} = Create.execute(params, build_form_data())

      assert [%{args: %{"meeting_id" => meeting_id}}] = all_enqueued(worker: SlackWorker)
      assert meeting_id == winner.id
    end
  end

  # These paths confirm a booking that is already committed, so they still
  # run the fan-out at once, through `Activation.activate/2`.
  describe "paths that activate after commit" do
    test "approving a request sends one Slack notice", %{user: user} do
      held =
        insert_meeting_for_user(user, %{
          status: "awaiting_approval",
          approval_requested_at: DateTime.utc_now(:second),
          approval_deadline_at: DateTime.add(DateTime.utc_now(:second), 1, :day)
        })

      assert {:ok, _confirmed} = Approval.approve(held)

      assert [_one] =
               all_enqueued(
                 worker: SlackWorker,
                 args: %{"meeting_id" => held.id, "event_type" => "meeting.created"}
               )
    end

    # The payment confirmation calls exactly this once its transaction has
    # committed (`MeetingPayments.Webhooks.CheckoutSessionCompleted`).
    test "activating a committed booking sends one Slack notice", %{user: user} do
      meeting = insert_meeting_for_user(user, %{status: "confirmed"})

      assert :ok = Activation.activate(meeting, with_video_room: true)

      assert [_one] = all_enqueued(worker: SlackWorker, args: %{"meeting_id" => meeting.id})
    end
  end

  defp assert_booking_stands(meeting) do
    assert Repo.get(MeetingSchema, meeting.id)

    assert_enqueued(
      worker: EmailWorker,
      args: %{"action" => "send_confirmation_emails", "meeting_id" => meeting.id}
    )
  end

  defp reported?(kind), do: Repo.exists?(from(e in Error, where: e.kind == ^kind))

  defp refuse_slack_jobs! do
    Repo.query!("""
    CREATE FUNCTION refuse_slack_jobs() RETURNS trigger AS $$
    BEGIN
      IF NEW.worker LIKE '%SlackWorker' THEN
        RAISE EXCEPTION 'slack delivery refused';
      END IF;
      RETURN NEW;
    END
    $$ LANGUAGE plpgsql
    """)

    Repo.query!("""
    CREATE TRIGGER refuse_slack_jobs BEFORE INSERT ON oban_jobs
    FOR EACH ROW EXECUTE FUNCTION refuse_slack_jobs()
    """)
  end
end
