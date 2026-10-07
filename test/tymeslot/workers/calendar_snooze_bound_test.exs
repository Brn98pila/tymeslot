defmodule Tymeslot.Workers.CalendarSnoozeBoundTest do
  @moduledoc """
  From Oban 2.24 a snooze costs no attempt, so a calendar job that waits out
  an open breaker by snoozing would wait for ever if its provider never
  recovered: its owner never told, no alert raised. Each calendar worker
  bounds those waits by the job's own execution count.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :workers
  @moduletag :calendar

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Workers.CalendarEventWorker
  alias Tymeslot.Workers.SyncGoogleCalendarWorker

  setup :verify_on_exit!

  describe "a calendar write waiting for an open breaker" do
    setup do
      meeting = insert(:meeting)

      stub(Tymeslot.CalendarMock, :create_event, fn _event_data, _user_id ->
        {:error, :circuit_open}
      end)

      %{args: %{"action" => "create", "meeting_id" => meeting.id}}
    end

    test "snoozes while under the bound", %{args: args} do
      assert {:snooze, _seconds} =
               perform_job(CalendarEventWorker, args, meta: %{"snoozed" => 10})
    end

    test "fails once the bound is reached, so the job can exhaust and alert", %{args: args} do
      assert {:error, reason} =
               perform_job(CalendarEventWorker, args, meta: %{"snoozed" => 11})

      assert reason =~ "did not recover"
    end
  end

  describe "a Google sync waiting for an open breaker" do
    setup do
      integration =
        insert(:calendar_integration, provider: "google", google_sync_token: "valid-sync-token")

      stub(GoogleCalendarAPIMock, :list_events_incremental, fn _integration ->
        {:error, :circuit_open}
      end)

      %{args: %{"calendar_integration_id" => integration.id}}
    end

    test "snoozes while under the bound", %{args: args} do
      assert {:snooze, 120} =
               perform_job(SyncGoogleCalendarWorker, args, meta: %{"snoozed" => 10})
    end

    test "fails once the bound is reached", %{args: args} do
      assert {:error, reason} =
               perform_job(SyncGoogleCalendarWorker, args, meta: %{"snoozed" => 11})

      assert reason =~ "did not recover"
    end
  end
end
