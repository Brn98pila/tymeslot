defmodule Tymeslot.Availability.MidnightRewritePropertyTest do
  @moduledoc """
  What rewriting 23:59 ends to midnight does to bookers: every slot the old
  engine offered is still offered, and every slot gained falls in the stretch
  the rewrite added, between an old 23:59 end and the midnight replacing it
  (it starts before that midnight and ends after the old end). On most days
  that stretch is one minute; where the clocks go back at midnight it also
  holds the repeated hour, which the old end, resolved to its first
  occurrence, left out. Compared, like the oracle property, only where the
  booker's midnight cuts no old window.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  @moduletag :availability

  import Tymeslot.Test.SlotGridHelpers

  alias Tymeslot.Availability.TimeSlots
  alias Tymeslot.Test.{LegacySlotEngine, MidnightRewrite}
  alias Tymeslot.Test.ScheduleGenerators, as: Gen
  alias Tymeslot.Utils.DateTimeUtils

  @gained :midnight_rewrite_gained

  property "a rewritten schedule keeps its slots and gains only slots in the added stretch" do
    Process.put(@gained, 0)

    check all(
            date <- Gen.date(),
            owner_tz <- Gen.zone(),
            user_tz <- Gen.zone(),
            duration <- Gen.duration(),
            interval <- Gen.interval(),
            days <- Gen.week(Gen.legacy_window()),
            overrides <- Gen.overrides(date, Gen.legacy_window()),
            time_off <- Gen.time_off(date),
            max_runs: 500
          ) do
      before =
        pure_config(days: days, overrides: overrides, time_off: time_off, interval: interval)

      unless LegacySlotEngine.cuts_window?(date, owner_tz, user_tz, before) do
        old = LegacySlotEngine.round_trip_slots(date, duration, owner_tz, user_tz, before)
        new = labels(date, duration, owner_tz, user_tz, MidnightRewrite.apply(before))

        assert old -- new == [], "the rewrite lost slots: #{inspect(old -- new)}"

        stretches = added_stretches(before, date, owner_tz)

        stray =
          Enum.reject(new -- old, fn label ->
            {:ok, time} = DateTimeUtils.parse_time_string(label)
            {:ok, start} = DateTimeUtils.resolve_local(date, time, user_tz)
            finish = DateTime.add(start, duration, :minute)

            Enum.any?(stretches, fn {old_end, new_end} ->
              DateTime.compare(start, new_end) == :lt and DateTime.compare(finish, old_end) == :gt
            end)
          end)

        assert stray == [],
               "gained slots outside the stretch the rewrite added: #{inspect(stray)}"

        if new != old, do: Process.put(@gained, Process.get(@gained) + 1)
      end
    end

    assert Process.get(@gained) > 0, "no run gained a slot, so the rewrite was never exercised"
  end

  describe "a Saturday open until 23:59 in Santiago, booked from Tokyo" do
    @owner_tz "America/Santiago"
    @user_tz "Asia/Tokyo"
    @saturday_until_2359 [
      %{day_of_week: 6, start_time: ~T[12:00:00], end_time: ~T[23:59:00]}
    ]

    # Chile leaves DST at 24:00 on Saturday 3 April 2027: the clocks go back
    # to 23:00, so Saturday's 23:xx hour happens twice. The old 23:59 end is
    # its first occurrence (-03); midnight comes an hour and a minute later
    # (00:00 -04), so the rewrite gains the slot running past the old end and
    # the whole repeated hour.
    test "gains the repeated hour when the clocks go back at midnight" do
      {old, new} = old_and_new(~D[2027-04-04])

      {:ambiguous, first_2345, _second} = DateTime.new(~D[2027-04-03], ~T[23:45:00], @owner_tz)

      repeated =
        for time <- [~T[23:00:00], ~T[23:15:00], ~T[23:30:00], ~T[23:45:00]] do
          {:ambiguous, _first, second} = DateTime.new(~D[2027-04-03], time, @owner_tz)
          second
        end

      assert old -- new == []
      assert new -- old == booker_labels([first_2345 | repeated])
    end

    # Chile enters DST at 24:00 on Saturday 4 September 2027: the clocks jump
    # to 01:00 on Sunday, so Sunday's midnight does not exist and resolves to
    # the end of the gap, the instant Saturday ends. The rewrite gains only
    # the last quarter hour before it, as on any other day.
    test "gains only the last quarter hour when the clocks go forward at midnight" do
      {old, new} = old_and_new(~D[2027-09-05])

      {:gap, _just_before, saturday_end} = DateTime.new(~D[2027-09-05], ~T[00:00:00], @owner_tz)
      {:ok, last_start} = DateTime.new(~D[2027-09-04], ~T[23:45:00], @owner_tz)

      assert DateTime.diff(saturday_end, last_start, :minute) == 15
      assert old -- new == []
      assert new -- old == booker_labels([last_start])
    end

    defp old_and_new(date) do
      before = pure_config(days: @saturday_until_2359)

      refute LegacySlotEngine.cuts_window?(date, @owner_tz, @user_tz, before)

      {LegacySlotEngine.round_trip_slots(date, 15, @owner_tz, @user_tz, before),
       labels(date, 15, @owner_tz, @user_tz, MidnightRewrite.apply(before))}
    end

    defp booker_labels(owner_starts),
      do:
        Enum.map(
          owner_starts,
          &(&1 |> DateTime.shift_zone!(@user_tz) |> TimeSlots.format_datetime_slot())
        )
  end

  # The stretch each rewritten row gained around the date: from its old 23:59
  # end (a repeated time read as its first occurrence, as the old engine read
  # it) to the next day's midnight that replaces it. Over-approximates (an
  # override hides its weekday's row), which only makes the check more
  # permissive, never wrong.
  defp added_stretches(config, date, owner_tz) do
    for owner_date <- Date.range(Date.add(date, -3), Date.add(date, 3)),
        rewritten_on?(config, owner_date),
        {:ok, old_end} = DateTimeUtils.resolve_local(owner_date, ~T[23:59:00], owner_tz),
        {:ok, new_end} =
          DateTimeUtils.resolve_local(Date.add(owner_date, 1), ~T[00:00:00], owner_tz),
        do: {old_end, new_end}
  end

  defp rewritten_on?(config, owner_date) do
    Enum.any?(config.overrides, &(&1.date == owner_date and MidnightRewrite.rewritten?(&1))) or
      Enum.any?(
        config.weekly_schedule,
        &(&1.day_of_week == Date.day_of_week(owner_date) and MidnightRewrite.rewritten?(&1))
      )
  end
end
