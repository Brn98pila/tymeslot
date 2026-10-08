defmodule Tymeslot.CalendarGrid.EventEditQueueForRetryTest do
  @moduledoc """
  A grid edit the grid's write queue could not finish is saved for a later
  sync (`Tymeslot.CalendarGrid.WriteHandOver`), from the same payload a
  direct write sends. A one-off given a repeat rule keeps the zone its
  series is written in, as the direct write does.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :calendar
  @moduletag :integration

  alias Tymeslot.CalendarGrid.EventEdit
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema

  test "a one-off given a rule is queued in the organiser's zone" do
    user = insert(:user)

    integration =
      insert(:calendar_integration,
        user: user,
        provider: "caldav",
        base_url: "https://caldav.example.com",
        calendar_paths: ["/cal/"]
      )

    row =
      insert(:provider_calendar_event,
        calendar_integration: integration,
        uid: "planning",
        provider: "caldav",
        provider_calendar_id: "/cal/",
        provider_event_id: "/cal/planning.ics",
        summary: "Planning",
        start_at: ~U[2026-10-05 07:00:00.000000Z],
        end_at: ~U[2026-10-05 08:00:00.000000Z],
        all_day: false,
        timezone: "Etc/UTC",
        sync_state: "synced"
      )

    event = ProviderCalendarEventSchema.to_calendar_event(row)

    assert {:ok, _updated} =
             EventEdit.queue_for_retry(user.id, event, %{recurrence_rule: "FREQ=WEEKLY"},
               timezone: "Europe/Berlin"
             )

    queued = Repo.reload!(row)
    assert queued.sync_state == "locally_modified"
    assert queued.recurrence_rule == "FREQ=WEEKLY"
    assert queued.timezone == "Europe/Berlin"
  end
end
