defmodule Tymeslot.Bookings.CancelRaceTest do
  @moduledoc """
  Cancel and reschedule act on a meeting struct read some time before they
  write: the public cancel page holds the one it loaded at mount, and a
  reschedule reads the meeting, then waits on the host's calendar provider.
  Whatever happened to the row in between must win over that stale copy.

  The interleavings are staged deterministically: the losing call is handed
  the struct read before the winner committed, or the winner commits from
  inside the reschedule's calendar fetch, which is exactly the window the
  stale struct is held across.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  import Mox
  import Tymeslot.AvailabilityTestHelpers
  import Tymeslot.MeetingTestHelpers

  @moduletag :bookings
  @moduletag :meetings
  @moduletag :integration

  alias Tymeslot.Bookings.Cancel
  alias Tymeslot.Bookings.Reschedule
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.CalendarEventWorker

  # Records every cancellation the notification pipeline is asked to send.
  # Oban's uniqueness window would fold a second cancellation job into the
  # first, hiding a repeated fan-out; this sees each request as it is made.
  defmodule RecordingEmailWorker do
    @spec schedule_cancellation_emails(String.t()) :: :ok
    def schedule_cancellation_emails(meeting_id) do
      send(self(), {:cancellation_emails_scheduled, meeting_id})
      :ok
    end

    @spec cancel_reminder_emails(String.t()) :: :ok
    def cancel_reminder_emails(_meeting_id), do: :ok
  end

  setup :verify_on_exit!

  setup do
    TestMocks.setup_email_mocks()
    TestMocks.stub_no_calendar_events()
    :ok
  end

  describe "two cancellations of the same meeting" do
    setup do
      original = Application.get_env(:tymeslot, :email_worker_module)
      Application.put_env(:tymeslot, :email_worker_module, RecordingEmailWorker)

      on_exit(fn ->
        if is_nil(original),
          do: Application.delete_env(:tymeslot, :email_worker_module),
          else: Application.put_env(:tymeslot, :email_worker_module, original)
      end)

      %{user: user} = create_user_with_profile()
      %{meeting: insert_meeting_for_user(user)}
    end

    test "announce the cancellation once, and the loser is told it was already cancelled",
         %{meeting: meeting} do
      # Both callers read the meeting while it was still confirmed.
      stale = meeting

      assert {:ok, cancelled} = Cancel.execute(stale, caller: :organizer)
      assert {:error, :already_cancelled} = Cancel.execute(stale, caller: :organizer)

      assert_received {:cancellation_emails_scheduled, id} when id == meeting.id
      refute_received {:cancellation_emails_scheduled, _id}

      assert {:ok, reloaded} = MeetingQueries.get_meeting(meeting.id)
      assert reloaded.status == "cancelled"
      assert reloaded.cancelled_at == cancelled.cancelled_at
    end

    test "an external calendar deletion arriving after a cancel neither re-announces nor rewrites it",
         %{meeting: meeting} do
      assert {:ok, _cancelled} = Cancel.execute(meeting, caller: :organizer)
      assert_received {:cancellation_emails_scheduled, _id}

      assert {:error, :already_cancelled} = Cancel.execute_external(meeting)
      refute_received {:cancellation_emails_scheduled, _id}

      assert {:ok, reloaded} = MeetingQueries.get_meeting(meeting.id)
      assert is_nil(reloaded.cancellation_reason)
    end
  end

  describe "a cancellation landing while a reschedule waits on the host's calendar" do
    test "leaves the meeting cancelled at its original time, with nothing announced" do
      %{meeting: meeting, user: user, params: params} = booking(false)

      cancel_during_calendar_fetch(meeting)
      expect(Tymeslot.EmailServiceMock, :send_reschedule_emails, 0, fn _details -> nil end)

      assert {:error, "Cannot reschedule a cancelled meeting"} =
               Reschedule.execute(meeting.uid, params, %{}, user.id)

      assert {:ok, reloaded} = MeetingQueries.get_meeting(meeting.id)
      assert reloaded.status == "cancelled"
      assert DateTime.compare(reloaded.start_time, meeting.start_time) == :eq
      assert DateTime.compare(reloaded.end_time, meeting.end_time) == :eq

      refute_enqueued(
        worker: CalendarEventWorker,
        args: %{"action" => "update", "meeting_id" => meeting.id}
      )
    end

    test "does not resurrect a meeting on an approval-gated type into the request queue" do
      %{meeting: meeting, user: user, params: params} = booking(true)

      cancel_during_calendar_fetch(meeting)

      assert {:error, "Cannot reschedule a cancelled meeting"} =
               Reschedule.execute(meeting.uid, params, %{}, user.id)

      assert {:ok, reloaded} = MeetingQueries.get_meeting(meeting.id)
      assert reloaded.status == "cancelled"
      assert is_nil(reloaded.approval_requested_at)
    end
  end

  defp booking(requires_approval) do
    %{user: user} = create_always_bookable_profile()

    meeting_type =
      insert(:meeting_type,
        user: user,
        user_id: user.id,
        requires_approval: requires_approval,
        approval_window_hours: 12
      )

    meeting =
      insert_meeting_for_user(user, %{meeting_type_id: meeting_type.id, status: "confirmed"})

    params = %{
      date: Date.to_string(Date.add(Date.utc_today(), 2)),
      time: "2:00 PM",
      duration: "60min",
      user_timezone: "America/New_York"
    }

    %{user: user, meeting: meeting, params: params}
  end

  # The reschedule has read and validated the meeting by the time it asks the
  # provider whether the new slot is free; the host's cancel commits then.
  defp cancel_during_calendar_fetch(meeting) do
    stub(Tymeslot.CalendarMock, :get_events_for_range_fresh, fn _user_id, _from, _to ->
      {:ok, _cancelled} = Cancel.execute(meeting, caller: :organizer)
      {:ok, []}
    end)
  end
end
