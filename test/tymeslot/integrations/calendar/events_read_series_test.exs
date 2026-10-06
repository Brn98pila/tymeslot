defmodule Tymeslot.Integrations.Calendar.EventsReadSeriesTest do
  # The live availability read of a CalDAV recurring series: expanded in the
  # series' own zone and with its moved occurrences taken out, exactly as the
  # sync expands it.
  use ExUnit.Case, async: true
  @moduletag :integrations
  @moduletag :calendar

  alias Tymeslot.Integrations.Calendar.EventsRead

  # A CalDAV collection as the server returns it: a `TZID=Europe/Berlin`
  # weekly series written in January (CET, UTC+1), plus one occurrence moved
  # from 09:00 to 14:00 by a `RECURRENCE-ID` override. Run through the real
  # parser, so the maps carry the UTC start and the zone exactly as the
  # CalDAV read path hands them over.
  defmodule BerlinSeriesProvider do
    alias Tymeslot.Integrations.Calendar.ICalParser

    @ics """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Test//EN
    BEGIN:VEVENT
    UID:berlin-weekly
    DTSTART;TZID=Europe/Berlin:20260105T090000
    DTEND;TZID=Europe/Berlin:20260105T100000
    RRULE:FREQ=WEEKLY
    SUMMARY:Weekly sync
    END:VEVENT
    BEGIN:VEVENT
    UID:berlin-weekly
    RECURRENCE-ID;TZID=Europe/Berlin:20260713T090000
    DTSTART;TZID=Europe/Berlin:20260713T140000
    DTEND;TZID=Europe/Berlin:20260713T150000
    SUMMARY:Weekly sync (moved)
    END:VEVENT
    END:VCALENDAR
    """

    @spec list_events(any(), keyword()) :: {:ok, list(map())}
    def list_events(_client, _opts), do: ICalParser.parse(@ics)
  end

  describe "CalDAV series on the live read path" do
    setup do
      %{
        client: %{
          provider_type: :fake,
          provider_module: BerlinSeriesProvider,
          client: %{calendar_path: "/cal/berlin"}
        }
      }
    end

    test "a winter-created Berlin series stays at 09:00 local in summer", %{client: client} do
      # Monday 6 July 2026, CEST (UTC+2): 09:00 local is 07:00 UTC.
      assert {:ok, events, "/cal/berlin"} =
               EventsRead.fetch_events_with_fallback(
                 client,
                 ~U[2026-07-06 00:00:00Z],
                 ~U[2026-07-07 00:00:00Z]
               )

      # The stub serves the 13 July override whatever the range; only the
      # series' own occurrence on the 6th is under test here.
      assert [%{start_time: starts, end_time: ends}] =
               Enum.filter(events, &is_nil(&1.recurrence_id))

      assert DateTime.compare(starts, ~U[2026-07-06 07:00:00Z]) == :eq
      assert DateTime.compare(ends, ~U[2026-07-06 08:00:00Z]) == :eq
    end

    test "a moved occurrence blocks only its new time", %{client: client} do
      assert {:ok, events, "/cal/berlin"} =
               EventsRead.fetch_events_with_fallback(
                 client,
                 ~U[2026-07-13 00:00:00Z],
                 ~U[2026-07-14 00:00:00Z]
               )

      # 14:00 CEST is 12:00 UTC; the original 09:00 slot (07:00 UTC) is free.
      assert [%{start_time: starts, end_time: ends, summary: "Weekly sync (moved)"}] = events
      assert DateTime.compare(starts, ~U[2026-07-13 12:00:00Z]) == :eq
      assert DateTime.compare(ends, ~U[2026-07-13 13:00:00Z]) == :eq
    end
  end
end
