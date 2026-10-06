defmodule Tymeslot.Integrations.Calendar.RecurrenceExpanderEdgeCasesTest do
  use ExUnit.Case, async: true

  @moduletag :calendar

  alias Tymeslot.Integrations.Calendar.ICalNormaliser
  alias Tymeslot.Integrations.Calendar.RecurrenceExpander

  describe "expand/4 with EXDATE exclusions" do
    test "excludes specific dates" do
      event = %{
        uid: "exdate-1",
        summary: "Weekly",
        start_time: ~U[2026-04-03 09:00:00Z],
        end_time: ~U[2026-04-03 10:00:00Z],
        recurrence_rule: "FREQ=WEEKLY;INTERVAL=1"
      }

      range_start = ~U[2026-04-01 00:00:00Z]
      range_end = ~U[2026-04-30 23:59:59Z]

      exdates = [~U[2026-04-10 09:00:00Z], ~U[2026-04-24 09:00:00Z]]
      occurrences = RecurrenceExpander.expand(event, range_start, range_end, exdates: exdates)
      starts = Enum.map(occurrences, & &1.start_time)

      assert ~U[2026-04-03 09:00:00Z] in starts
      assert ~U[2026-04-17 09:00:00Z] in starts
      refute ~U[2026-04-10 09:00:00Z] in starts
      refute ~U[2026-04-24 09:00:00Z] in starts
    end

    test "excludes Date-valued EXDATEs from all-day recurring events" do
      event = %{
        uid: "exdate-allday-1",
        summary: "All-day weekly",
        start_time: ~D[2026-04-03],
        end_time: ~D[2026-04-04],
        recurrence_rule: "FREQ=WEEKLY;INTERVAL=1"
      }

      range_start = ~U[2026-04-01 00:00:00Z]
      range_end = ~U[2026-04-30 23:59:59Z]

      exdates = [~D[2026-04-10], ~D[2026-04-24]]
      occurrences = RecurrenceExpander.expand(event, range_start, range_end, exdates: exdates)
      starts = Enum.map(occurrences, & &1.start_time)

      assert ~D[2026-04-03] in starts
      assert ~D[2026-04-17] in starts
      refute ~D[2026-04-10] in starts
      refute ~D[2026-04-24] in starts
    end
  end

  describe "expand/4 with all-day events (Date structs)" do
    test "expands weekly all-day event" do
      event = %{
        uid: "allday-weekly-1",
        summary: "Team Lunch",
        start_time: ~D[2026-04-03],
        end_time: ~D[2026-04-04],
        recurrence_rule: "FREQ=WEEKLY;INTERVAL=1"
      }

      range_start = ~U[2026-04-01 00:00:00Z]
      range_end = ~U[2026-04-30 23:59:59Z]

      occurrences = RecurrenceExpander.expand(event, range_start, range_end)
      starts = Enum.map(occurrences, & &1.start_time)

      assert ~D[2026-04-03] in starts
      assert ~D[2026-04-10] in starts
      assert ~D[2026-04-17] in starts
      assert ~D[2026-04-24] in starts
      assert length(occurrences) == 4
    end

    test "preserves Date structs in expanded occurrences" do
      event = %{
        uid: "allday-daily-1",
        summary: "Daily Reminder",
        start_time: ~D[2026-04-01],
        end_time: ~D[2026-04-02],
        recurrence_rule: "FREQ=DAILY;COUNT=3"
      }

      range_start = ~U[2026-04-01 00:00:00Z]
      range_end = ~U[2026-04-30 23:59:59Z]

      occurrences = RecurrenceExpander.expand(event, range_start, range_end)

      assert [
               %{start_time: ~D[2026-04-01], end_time: ~D[2026-04-02]},
               %{start_time: ~D[2026-04-02], end_time: ~D[2026-04-03]},
               %{start_time: ~D[2026-04-03], end_time: ~D[2026-04-04]}
             ] = occurrences
    end

    test "expands multi-day all-day event preserving duration" do
      event = %{
        uid: "allday-multi-1",
        summary: "Conference",
        start_time: ~D[2026-04-06],
        end_time: ~D[2026-04-08],
        recurrence_rule: "FREQ=MONTHLY;INTERVAL=1;COUNT=2"
      }

      range_start = ~U[2026-04-01 00:00:00Z]
      range_end = ~U[2026-06-30 23:59:59Z]

      occurrences = RecurrenceExpander.expand(event, range_start, range_end)

      assert [
               %{start_time: ~D[2026-04-06], end_time: ~D[2026-04-08]},
               %{start_time: ~D[2026-05-06], end_time: ~D[2026-05-08]}
             ] = occurrences
    end

    test "handles range_start and range_end as Date structs" do
      event = %{
        uid: "allday-range-1",
        summary: "All-day",
        start_time: ~D[2026-04-03],
        end_time: ~D[2026-04-04],
        recurrence_rule: "FREQ=WEEKLY;COUNT=3"
      }

      range_start = ~D[2026-04-01]
      range_end = ~D[2026-04-30]

      occurrences = RecurrenceExpander.expand(event, range_start, range_end)

      assert length(occurrences) == 3
    end
  end

  describe "expand/4 boundary edges" do
    # These cases pin behaviour at the awkward corners of RRULE expansion
    # where a naive loop could either produce phantom occurrences or
    # silently skip the master event. `COUNT=0` is legal per RFC 5545
    # (though rarely seen in the wild) and must collapse to the empty
    # list; `UNTIL < DTSTART` is a nonsense rule that some CalDAV clients
    # still emit during bulk-edit flows and must likewise collapse
    # without falling through to the fail-open "return master" arm.

    test "COUNT=0 produces an empty expansion, not a single fail-open occurrence" do
      event = %{
        uid: "count-zero",
        summary: "Nothing",
        start_time: ~U[2026-04-03 09:00:00Z],
        end_time: ~U[2026-04-03 10:00:00Z],
        recurrence_rule: "FREQ=WEEKLY;COUNT=0"
      }

      occurrences =
        RecurrenceExpander.expand(event, ~U[2026-04-01 00:00:00Z], ~U[2026-05-31 23:59:59Z])

      assert occurrences == []
    end

    test "UNTIL strictly before DTSTART produces an empty expansion" do
      event = %{
        uid: "until-before-start",
        summary: "Already expired",
        start_time: ~U[2026-04-03 09:00:00Z],
        end_time: ~U[2026-04-03 10:00:00Z],
        recurrence_rule: "FREQ=WEEKLY;UNTIL=20260101T000000Z"
      }

      occurrences =
        RecurrenceExpander.expand(event, ~U[2026-04-01 00:00:00Z], ~U[2026-05-31 23:59:59Z])

      assert occurrences == []
    end

    test "all-day series honours a DATE-form UNTIL instead of running unbounded" do
      # The recurrence editor emits a bare-date UNTIL for all-day events. If the
      # expander can't parse it, the series is treated as endless and paints
      # occurrences past its intended end (capped only by @max_occurrences).
      event = %{
        uid: "allday-until",
        summary: "All-day standup",
        start_time: ~D[2026-04-01],
        end_time: ~D[2026-04-02],
        recurrence_rule: "FREQ=DAILY;UNTIL=20260405"
      }

      occurrences =
        RecurrenceExpander.expand(event, ~U[2026-04-01 00:00:00Z], ~U[2026-04-30 23:59:59Z])

      starts = Enum.map(occurrences, & &1.start_time)

      # Inclusive through the UNTIL date, nothing after it.
      assert starts == [
               ~D[2026-04-01],
               ~D[2026-04-02],
               ~D[2026-04-03],
               ~D[2026-04-04],
               ~D[2026-04-05]
             ]
    end
  end

  describe "expand/4 across daylight-saving transitions" do
    # A recurring event must keep its *local wall-clock* time across a DST
    # change. "Every Monday at 15:00 Berlin" stays 15:00 even after the clocks
    # change — the absolute UTC instant is what shifts by an hour, not the time
    # the user sees. The regression these pin: stepping with DateTime.add/3
    # (instant arithmetic) holds the UTC instant fixed and silently drifts the
    # local time, so a 15:00 series would show as 14:00 after the autumn change.

    test "weekly series keeps its local time across the autumn fall-back" do
      # Europe/Berlin falls back from CEST (+02:00) to CET (+01:00) on
      # 2026-10-25. The series is anchored two weeks before, in summer time.
      anchor = DateTime.new!(~D[2026-10-12], ~T[15:00:00], "Europe/Berlin")

      event = %{
        uid: "dst-weekly",
        summary: "Weekly sync",
        start_time: anchor,
        end_time: DateTime.new!(~D[2026-10-12], ~T[16:00:00], "Europe/Berlin"),
        recurrence_rule: "FREQ=WEEKLY;INTERVAL=1"
      }

      occurrences =
        RecurrenceExpander.expand(
          event,
          ~U[2026-10-01 00:00:00Z],
          ~U[2026-11-15 23:59:59Z]
        )

      # Every occurrence reads 15:00 local, on both sides of the transition.
      assert Enum.all?(occurrences, &(DateTime.to_time(&1.start_time) == ~T[15:00:00]))

      utc_by_date =
        Map.new(occurrences, fn occ ->
          {DateTime.to_date(occ.start_time), DateTime.shift_zone!(occ.start_time, "Etc/UTC")}
        end)

      # Before the change: 15:00 CEST == 13:00 UTC.
      assert utc_by_date[~D[2026-10-19]] == ~U[2026-10-19 13:00:00Z]
      # After the change: 15:00 CET == 14:00 UTC (the instant moved, not the clock).
      assert utc_by_date[~D[2026-10-26]] == ~U[2026-10-26 14:00:00Z]
      assert utc_by_date[~D[2026-11-02]] == ~U[2026-11-02 14:00:00Z]
    end

    test "weekly BYDAY series keeps its local time across the autumn fall-back" do
      # The single-weekday BYDAY shape (what the recurrence editor emits by
      # default) steps through advance_to_next_byday/3's week-wrap branch on
      # every iteration — since BYDAY=MO never has a later weekday in the same
      # week. That branch must stay in the event's own timezone, exactly like
      # the plain-weekly path above, or a 15:00 Monday series drifts to 14:00
      # after Berlin's 2026-10-25 fall-back.
      anchor = DateTime.new!(~D[2026-10-12], ~T[15:00:00], "Europe/Berlin")

      event = %{
        uid: "dst-weekly-byday",
        summary: "Monday standup",
        start_time: anchor,
        end_time: DateTime.new!(~D[2026-10-12], ~T[15:30:00], "Europe/Berlin"),
        recurrence_rule: "FREQ=WEEKLY;BYDAY=MO"
      }

      occurrences =
        RecurrenceExpander.expand(
          event,
          ~U[2026-10-01 00:00:00Z],
          ~U[2026-11-15 23:59:59Z]
        )

      assert Enum.all?(occurrences, &(DateTime.to_time(&1.start_time) == ~T[15:00:00]))

      utc_by_date =
        Map.new(occurrences, fn occ ->
          {DateTime.to_date(occ.start_time), DateTime.shift_zone!(occ.start_time, "Etc/UTC")}
        end)

      # All Mondays, so the fall-back must land the instant an hour later in UTC
      # while the wall clock stays at 15:00.
      assert utc_by_date[~D[2026-10-19]] == ~U[2026-10-19 13:00:00Z]
      assert utc_by_date[~D[2026-10-26]] == ~U[2026-10-26 14:00:00Z]
      assert utc_by_date[~D[2026-11-02]] == ~U[2026-11-02 14:00:00Z]
    end

    test "monthly series keeps its local time across a DST transition" do
      anchor = DateTime.new!(~D[2026-09-15], ~T[09:30:00], "Europe/Berlin")

      event = %{
        uid: "dst-monthly",
        summary: "Monthly review",
        start_time: anchor,
        end_time: DateTime.new!(~D[2026-09-15], ~T[10:30:00], "Europe/Berlin"),
        recurrence_rule: "FREQ=MONTHLY;INTERVAL=1"
      }

      occurrences =
        RecurrenceExpander.expand(
          event,
          ~U[2026-09-01 00:00:00Z],
          ~U[2026-11-30 23:59:59Z]
        )

      assert Enum.all?(occurrences, &(DateTime.to_time(&1.start_time) == ~T[09:30:00]))

      utc_by_date =
        Map.new(occurrences, fn occ ->
          {DateTime.to_date(occ.start_time), DateTime.shift_zone!(occ.start_time, "Etc/UTC")}
        end)

      # September (CEST): 09:30 == 07:30 UTC. November (CET): 09:30 == 08:30 UTC.
      assert utc_by_date[~D[2026-09-15]] == ~U[2026-09-15 07:30:00Z]
      assert utc_by_date[~D[2026-11-15]] == ~U[2026-11-15 08:30:00Z]
    end
  end

  describe "expand/4 for a series that started long before the range" do
    # The safety cap bounds the occurrences a range gets, not the steps taken
    # from the series' first start: a standing meeting that has run for years
    # must still block this week's slots.

    @week_start ~U[2026-10-05 00:00:00Z]
    @week_end ~U[2026-10-11 23:59:59Z]

    defp berlin(date, time), do: DateTime.new!(date, time, "Europe/Berlin")

    defp old_series(rule, first_day) do
      %{
        uid: "old-series",
        summary: "Standing meeting",
        start_time: berlin(first_day, ~T[09:00:00]),
        end_time: berlin(first_day, ~T[09:30:00]),
        recurrence_rule: rule
      }
    end

    defp dates(occurrences), do: Enum.map(occurrences, &DateTime.to_date(&1.start_time))

    test "a daily series from three years ago occurs every day this week, at its own time" do
      occurrences =
        "FREQ=DAILY"
        |> old_series(~D[2023-10-02])
        |> RecurrenceExpander.expand(@week_start, @week_end)

      assert dates(occurrences) == Enum.to_list(Date.range(~D[2026-10-05], ~D[2026-10-11]))
      # Three years of DST changes later, the wall clock still reads 09:00.
      assert Enum.reject(occurrences, &(DateTime.to_time(&1.start_time) == ~T[09:00:00])) == []
    end

    test "a weekday series from three years ago occurs Monday to Friday this week" do
      occurrences =
        "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR"
        |> old_series(~D[2023-10-02])
        |> RecurrenceExpander.expand(@week_start, @week_end)

      assert dates(occurrences) == Enum.to_list(Date.range(~D[2026-10-05], ~D[2026-10-09]))
    end

    test "a fortnightly series from three years ago keeps to its own weeks" do
      # 2023-10-02 to 2026-09-28 is 156 weeks, so of the three weeks from
      # 21 September the series is on only in the week of 28 September. The
      # range is chosen so that a skip by an odd number of weeks would land
      # in the off weeks.
      occurrences =
        "FREQ=WEEKLY;INTERVAL=2;BYDAY=TU,TH"
        |> old_series(~D[2023-10-03])
        |> RecurrenceExpander.expand(~U[2026-09-21 00:00:00Z], @week_end)

      assert dates(occurrences) == [~D[2026-09-29], ~D[2026-10-01]]
    end

    test "a series whose COUNT ran out years ago has no occurrences this week" do
      occurrences =
        "FREQ=DAILY;COUNT=10"
        |> old_series(~D[2023-10-02])
        |> RecurrenceExpander.expand(@week_start, @week_end)

      assert occurrences == []
    end

    test "the cap bounds the occurrences inside the range, counted from its start" do
      occurrences =
        "FREQ=DAILY"
        |> old_series(~D[2023-10-02])
        |> RecurrenceExpander.expand(~U[2026-01-01 00:00:00Z], ~U[2030-12-31 23:59:59Z])

      assert length(occurrences) == 500
      assert hd(dates(occurrences)) == ~D[2026-01-01]
    end

    test "a rule that never moves forward is unreadable, so its event shows once" do
      # INTERVAL=0 (or below) would step on the same period for ever. RFC 5545
      # requires a positive INTERVAL, so the rule is refused like any other
      # invalid rule and the event is returned as it is.
      for rule <- ["FREQ=DAILY;INTERVAL=0", "FREQ=WEEKLY;INTERVAL=-1;BYDAY=MO,WE"] do
        event = old_series(rule, ~D[2023-10-02])

        assert RecurrenceExpander.parse_rrule(rule) == :error
        assert RecurrenceExpander.expand(event, @week_start, @week_end) == [event]
        assert RecurrenceExpander.count_before(rule, event.start_time, @week_start) == 1
      end
    end

    test "a feed full of rules that never move forward expands quickly" do
      # Each such rule once spent the whole step budget (about a quarter of a
      # second) before giving up, so a hostile feed stalled availability.
      events =
        for n <- 1..200,
            do: old_series("FREQ=DAILY;INTERVAL=0;COUNT=#{n + 1_000_000}", ~D[1900-01-01])

      {micros, expanded} =
        :timer.tc(fn ->
          Enum.flat_map(events, &RecurrenceExpander.expand(&1, @week_start, @week_end))
        end)

      assert micros < 1_000_000
      assert expanded == events
    end

    test "the live busy-time check sees this week's occurrence of a years-old series" do
      raw = %{
        uid: "old-standup",
        summary: "Standup",
        timezone: "Europe/Berlin",
        dtstart: DateTime.shift_zone!(berlin(~D[2023-10-02], ~T[09:00:00]), "Etc/UTC"),
        dtend: DateTime.shift_zone!(berlin(~D[2023-10-02], ~T[09:30:00]), "Etc/UTC"),
        rrule: "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR"
      }

      starts =
        [raw]
        |> ICalNormaliser.expand_occurrences(@week_start, @week_end)
        |> Enum.map(& &1.start_time)

      # 09:00 CEST is 07:00 UTC.
      assert ~U[2026-10-07 07:00:00Z] in starts
      assert length(starts) == 5
    end
  end
end
