defmodule Tymeslot.Integrations.Calendar.ICalBuilder.TimeZoneComponentTest do
  @moduledoc """
  A timed series Tymeslot writes to a CalDAV calendar carries its zone:
  `DTSTART`, `DTEND` and `EXDATE` as wall clocks with a `TZID`, and a
  `VTIMEZONE` built from the time zone database beside them. Single events,
  all-day series and series without a known zone keep the UTC and DATE forms.
  """
  use ExUnit.Case, async: true

  @moduletag :calendar
  @moduletag :integrations
  @moduletag :unit

  alias Tymeslot.Integrations.Calendar.ICalBuilder
  alias Tymeslot.Integrations.Calendar.ICalBuilder.LineFolder
  alias Tymeslot.Integrations.Calendar.ICalBuilder.TimeZoneComponent

  # Monday 5 October 2026, 09:00 in Berlin (CEST, UTC+2).
  @start ~U[2026-10-05 07:00:00Z]

  defp series(overrides \\ %{}) do
    Map.merge(
      %{
        summary: "Weekly sync",
        start_time: @start,
        end_time: DateTime.add(@start, 30, :minute),
        recurrence_rule: "FREQ=WEEKLY",
        series_timezone: "Europe/Berlin"
      },
      overrides
    )
  end

  describe "lines/3" do
    test "writes each offset change as its own observance, from the one in force" do
      assert TimeZoneComponent.lines(
               "Europe/Berlin",
               ~U[2026-01-05 08:00:00Z],
               ~U[2027-01-05 08:00:00Z]
             ) == [
               "BEGIN:VTIMEZONE",
               "TZID:Europe/Berlin",
               "BEGIN:STANDARD",
               "DTSTART:20251026T030000",
               "TZOFFSETFROM:+0200",
               "TZOFFSETTO:+0100",
               "TZNAME:CET",
               "END:STANDARD",
               "BEGIN:DAYLIGHT",
               "DTSTART:20260329T020000",
               "TZOFFSETFROM:+0100",
               "TZOFFSETTO:+0200",
               "TZNAME:CEST",
               "END:DAYLIGHT",
               "BEGIN:STANDARD",
               "DTSTART:20261025T030000",
               "TZOFFSETFROM:+0200",
               "TZOFFSETTO:+0100",
               "TZNAME:CET",
               "END:STANDARD",
               "END:VTIMEZONE"
             ]
    end

    test "gives a zone without DST one fixed observance" do
      lines =
        TimeZoneComponent.lines(
          "Asia/Kolkata",
          ~U[2026-01-05 08:00:00Z],
          ~U[2027-01-05 08:00:00Z]
        )

      assert Enum.count(lines, &(&1 == "BEGIN:STANDARD")) == 1
      assert "TZOFFSETFROM:+0530" in lines
      assert "TZOFFSETTO:+0530" in lines
      refute "BEGIN:DAYLIGHT" in lines
    end

    test "writes a half-hour offset change" do
      lines =
        TimeZoneComponent.lines(
          "Australia/Lord_Howe",
          ~U[2026-01-05 08:00:00Z],
          ~U[2027-01-05 08:00:00Z]
        )

      assert "TZOFFSETTO:+1030" in lines
      assert "TZOFFSETTO:+1100" in lines
    end

    test "has nothing to write for a zone the database does not know" do
      assert TimeZoneComponent.lines("Nowhere/Zone", @start, DateTime.add(@start, 1, :day)) ==
               nil
    end
  end

  describe "series_zone/1" do
    test "is the payload's zone for a timed series" do
      assert TimeZoneComponent.series_zone(series()) == "Europe/Berlin"
    end

    test "is nil wherever the UTC or DATE form stays" do
      for payload <- [
            series(%{recurrence_rule: nil}),
            series(%{recurrence_rule: ""}),
            series(%{all_day: true}),
            series(%{start_time: ~D[2026-10-05], end_time: ~D[2026-10-06]}),
            series(%{series_timezone: "Etc/UTC"}),
            series(%{series_timezone: "Nowhere/Zone"}),
            Map.delete(series(), :series_timezone)
          ] do
        assert TimeZoneComponent.series_zone(payload) == nil
      end
    end
  end

  describe "for_series/2" do
    test "spans the series up to its UNTIL" do
      lines =
        TimeZoneComponent.for_series(
          series(%{recurrence_rule: "FREQ=WEEKLY;UNTIL=20261231T225959Z"}),
          "Europe/Berlin"
        )

      # The observance in force (CEST since March) and the October change.
      assert Enum.count(lines, &String.starts_with?(&1, "BEGIN:STANDARD")) +
               Enum.count(lines, &String.starts_with?(&1, "BEGIN:DAYLIGHT")) == 2
    end

    test "spans ten years for a series with no UNTIL, whatever its UNTIL says beyond" do
      for rule <- ["FREQ=WEEKLY", "FREQ=WEEKLY;COUNT=3", "FREQ=WEEKLY;UNTIL=20991231T000000Z"] do
        lines = TimeZoneComponent.for_series(series(%{recurrence_rule: rule}), "Europe/Berlin")

        # The observance in force, then two changes a year for ten years.
        assert Enum.count(lines, &(&1 in ["BEGIN:STANDARD", "BEGIN:DAYLIGHT"])) == 21
      end
    end
  end

  describe "build_simple_event/3" do
    test "writes a timed series' timing and exclusions in its zone, beside its VTIMEZONE" do
      lines =
        series(%{recurrence_exceptions: [~D[2026-10-12], ~U[2026-11-02 08:00:00Z]]})
        |> then(&ICalBuilder.build_simple_event("sync-1", &1))
        |> LineFolder.unfold_lines()

      assert "DTSTART;TZID=Europe/Berlin:20261005T090000" in lines
      assert "DTEND;TZID=Europe/Berlin:20261005T093000" in lines
      assert "EXDATE;TZID=Europe/Berlin:20261012T090000,20261102T090000" in lines
      assert "RRULE:FREQ=WEEKLY" in lines

      # The VTIMEZONE comes before the VEVENT that names it.
      assert Enum.find_index(lines, &(&1 == "BEGIN:VTIMEZONE")) <
               Enum.find_index(lines, &(&1 == "BEGIN:VEVENT"))
    end

    test "keeps a single event and a series without a zone in UTC" do
      for payload <- [series(%{recurrence_rule: nil}), Map.delete(series(), :series_timezone)] do
        lines = "sync-1" |> ICalBuilder.build_simple_event(payload) |> LineFolder.unfold_lines()

        assert "DTSTART:20261005T070000Z" in lines
        refute "BEGIN:VTIMEZONE" in lines
      end
    end
  end

  describe "patch_event_properties/3" do
    # A one-off event as Tymeslot wrote it before it was given a rule.
    @single """
    BEGIN:VCALENDAR\r
    VERSION:2.0\r
    PRODID:-//Tymeslot//CalDAV Client//EN\r
    BEGIN:VEVENT\r
    UID:sync-1\r
    DTSTAMP:20261001T090000Z\r
    DTSTART:20261005T070000Z\r
    DTEND:20261005T073000Z\r
    SUMMARY:Weekly sync\r
    END:VEVENT\r
    END:VCALENDAR\r
    """

    test "writes a single event given a rule in its zone, with one VTIMEZONE" do
      once = ICalBuilder.patch_event_properties(@single, series())
      twice = ICalBuilder.patch_event_properties(once, series())

      for document <- [once, twice] do
        lines = LineFolder.unfold_lines(document)

        assert "DTSTART;TZID=Europe/Berlin:20261005T090000" in lines
        assert "DTEND;TZID=Europe/Berlin:20261005T093000" in lines
        refute "DTSTART:20261005T070000Z" in lines
        assert Enum.count(lines, &(&1 == "BEGIN:VTIMEZONE")) == 1

        assert Enum.find_index(lines, &(&1 == "BEGIN:VTIMEZONE")) <
                 Enum.find_index(lines, &(&1 == "BEGIN:VEVENT"))
      end
    end

    test "keeps a single event's edit in UTC" do
      lines =
        @single
        |> ICalBuilder.patch_event_properties(series(%{recurrence_rule: nil}))
        |> LineFolder.unfold_lines()

      assert "DTSTART:20261005T070000Z" in lines
      refute "BEGIN:VTIMEZONE" in lines
    end
  end
end
