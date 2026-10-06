defmodule Tymeslot.Integrations.Calendar.RecurrenceExpander do
  @moduledoc """
  Expands recurring calendar events (RRULE) into individual occurrences
  within a given date range.

  CalDAV servers return master events with RRULE strings and the original
  start/end times. This module generates concrete occurrences so the
  availability layer can detect conflicts on future dates.

  Google Calendar handles this server-side with `singleEvents=true`;
  this module provides the equivalent for CalDAV providers.
  """

  alias Tymeslot.Utils.DateTimeUtils

  @day_atoms %{
    "MO" => :monday,
    "TU" => :tuesday,
    "WE" => :wednesday,
    "TH" => :thursday,
    "FR" => :friday,
    "SA" => :saturday,
    "SU" => :sunday
  }

  @day_numbers %{
    monday: 1,
    tuesday: 2,
    wednesday: 3,
    thursday: 4,
    friday: 5,
    saturday: 6,
    sunday: 7
  }

  # Safety cap: `expand/4` never returns more than this many occurrences of
  # one event, however wide the range. It counts occurrences inside the range,
  # not steps from the series' first start, so a series that has run for years
  # still shows in this week's range.
  @max_occurrences 500

  # Runaway guard: `expand/4` stops after this many steps whatever they yield,
  # so a rule that never reaches the range (or never moves forward at all, such
  # as `INTERVAL=0`) cannot spin for ever. A series without `COUNT` is first
  # fast-forwarded to the range when its period is fixed (`fast_forward/3`), so
  # this only binds on rules that cannot be.
  @max_steps 100_000

  # The rule parts `generate_occurrences/6` steps through as the providers do
  # (see `countable?/1`).
  @countable_parts ~w(FREQ INTERVAL COUNT UNTIL BYDAY WKST)

  @doc """
  Expands a single event into its occurrences within `[range_start, range_end]`.

  Non-recurring events (nil recurrence_rule) are returned as a single-element list.
  Events with an unparseable RRULE are also returned as-is (fail-open: better to
  show the master event than silently drop it).

  ## Options

    * `:exdates` - list of `DateTime` values to exclude (cancelled occurrences)

  """
  @spec expand(map(), DateTime.t() | Date.t(), DateTime.t() | Date.t(), keyword()) :: [map()]
  def expand(event, range_start, range_end, opts \\ [])

  def expand(%{recurrence_rule: nil} = event, _range_start, _range_end, _opts), do: [event]
  def expand(%{recurrence_rule: ""} = event, _range_start, _range_end, _opts), do: [event]

  def expand(%{recurrence_rule: rrule} = event, range_start, range_end, opts)
      when is_binary(rrule) do
    exdates = Keyword.get(opts, :exdates, [])

    case parse_rrule(rrule) do
      {:ok, rule} ->
        generate_occurrences(event, rule, range_start, range_end, exdates, :capped)

      :error ->
        # Fail-open: return the original event rather than silently dropping it
        [event]
    end
  end

  def expand(event, _range_start, _range_end, _opts), do: [event]

  @doc """
  How many occurrences `rule` makes from `first`, the series' first start, up
  to but not including `boundary`, counted exactly as `expand/4` generates
  them. Excluded occurrences are not left out: RFC 5545 counts them towards
  a `COUNT` all the same.

  Splitting a series in two at `boundary` takes this many occurrences off the
  second half's `COUNT`. `first` is a `Date` for an all-day series and a
  `DateTime` in the series' own zone for a timed one, so the count steps on
  its wall clock across a DST change.

  Unlike `expand/4`, the count is not capped at #{@max_occurrences}
  occurrences and steps through every one from `first`: `boundary` bounds it, and so does the rule's own `COUNT`, so
  a split far into a long series still takes the right number off. The count
  is only right for a rule `countable?/1` accepts.
  """
  @spec count_before(String.t(), Date.t() | DateTime.t(), Date.t() | DateTime.t()) ::
          non_neg_integer()
  def count_before(rule, first, boundary) do
    last = boundary |> step_datetime() |> DateTime.add(-1, :second)
    event = %{start_time: first, end_time: first, recurrence_rule: rule}

    case parse_rrule(rule) do
      {:ok, parsed} ->
        event |> generate_occurrences(parsed, first, last, [], :uncapped) |> length()

      # `expand/4` shows an unreadable rule's event once, as it is.
      :error ->
        1
    end
  end

  @doc """
  Whether `rule` repeats only by the parts this module steps through as the
  providers do, so that `count_before/3` counts its occurrences exactly: a
  `COUNT` over any other part (`BYMONTHDAY`, `BYSETPOS`, an ordinal `BYDAY`
  such as `2MO`) would be counted wrongly, and a series split by that count
  would end on another date than it did.

  Weeks are counted from Monday, so a rule repeating on several days every
  few weeks from another week start is countable only when that makes no
  difference.
  """
  @spec countable?(String.t()) :: boolean()
  def countable?(rule) when is_binary(rule) do
    parts =
      rule
      |> String.replace_prefix("RRULE:", "")
      |> String.split(";", trim: true)
      |> Map.new(fn part ->
        case String.split(part, "=", parts: 2) do
          [name, value] -> {String.upcase(name), String.upcase(value)}
          [name] -> {String.upcase(name), ""}
        end
      end)

    days = parts |> Map.get("BYDAY", "") |> String.split(",", trim: true)

    Enum.all?(Map.keys(parts), &(&1 in @countable_parts)) and
      not Enum.any?(days, &String.match?(&1, ~r/\d/)) and
      (Map.get(parts, "WKST", "MO") == "MO" or Map.get(parts, "INTERVAL", "1") == "1" or
         length(days) < 2)
  end

  @doc """
  Parses an RRULE string into a structured map.

  Supported properties: FREQ, INTERVAL, UNTIL, COUNT, BYDAY.
  Returns `{:ok, map()}` or `:error`.
  """
  @spec parse_rrule(String.t() | nil) :: {:ok, map()} | :error
  def parse_rrule(nil), do: :error
  def parse_rrule(""), do: :error

  def parse_rrule(rrule) when is_binary(rrule) do
    # Strip "RRULE:" prefix if present (some parsers include it, some don't)
    rule_str = String.replace_prefix(rrule, "RRULE:", "")

    parts =
      rule_str
      |> String.split(";")
      |> Enum.reduce(%{}, fn part, acc ->
        case String.split(part, "=", parts: 2) do
          [key, value] -> Map.put(acc, String.upcase(key), value)
          _other -> acc
        end
      end)

    case parse_freq(parts["FREQ"]) do
      {:ok, freq} ->
        {:ok,
         %{
           freq: freq,
           interval: parse_int(parts["INTERVAL"], 1),
           until: parse_until(parts["UNTIL"]),
           count: parse_int(parts["COUNT"], nil),
           by_day: parse_byday(parts["BYDAY"])
         }}

      :error ->
        :error
    end
  end

  # --- Private: RRULE field parsers ---

  defp parse_freq("DAILY"), do: {:ok, :daily}
  defp parse_freq("WEEKLY"), do: {:ok, :weekly}
  defp parse_freq("MONTHLY"), do: {:ok, :monthly}
  defp parse_freq("YEARLY"), do: {:ok, :yearly}
  defp parse_freq(_other), do: :error

  defp parse_int(nil, default), do: default

  defp parse_int(str, default) do
    case Integer.parse(str) do
      {n, ""} -> n
      _other -> default
    end
  end

  defp parse_until(nil), do: nil

  defp parse_until(str) do
    case DateTime.from_iso8601(format_ical_datetime(str)) do
      {:ok, dt, _offset} -> dt
      _error -> nil
    end
  end

  # RFC 5545 UNTIL values without a trailing "Z" represent local/floating time,
  # but we have no timezone context here. Treat bare datetimes as UTC — this is
  # a lossy but safe default for CalDAV, where most servers emit Z-suffixed values.
  defp format_ical_datetime(
         <<y::binary-size(4), mo::binary-size(2), d::binary-size(2), "T", h::binary-size(2),
           mi::binary-size(2), s::binary-size(2), _rest::binary>>
       ) do
    "#{y}-#{mo}-#{d}T#{h}:#{mi}:#{s}Z"
  end

  # DATE-form UNTIL (RFC 5545 §3.3.10): all-day recurrences carry a bare date.
  # Expand it to end-of-day UTC so the final day stays inclusive — without this
  # the bare value fails to parse, `parse_until` returns nil, and the series is
  # silently treated as unbounded (capped only by @max_occurrences).
  defp format_ical_datetime(<<y::binary-size(4), mo::binary-size(2), d::binary-size(2)>>) do
    "#{y}-#{mo}-#{d}T23:59:59Z"
  end

  defp format_ical_datetime(other), do: other

  defp parse_byday(nil), do: nil

  defp parse_byday(str) do
    days =
      str
      |> String.split(",")
      |> Enum.map(fn day_str ->
        day_code = String.replace(day_str, ~r/^-?\d+/, "")
        Map.get(@day_atoms, String.upcase(day_code))
      end)
      |> Enum.reject(&is_nil/1)

    if days == [], do: nil, else: days
  end

  # --- Private: Occurrence generation ---

  # `:capped` (for `expand/4`) fast-forwards to the range where it can, and
  # bounds the steps by `@max_steps` and the occurrences returned by
  # `@max_occurrences`. `:uncapped` (for `count_before/3`) steps every
  # occurrence from the first start, bounded only by the rule's own end and
  # `range_end`, so the count it makes is exact.
  defp generate_occurrences(event, rule, range_start, range_end, exdates, limits) do
    # All-day events store Date structs; normalise to DateTime for uniform arithmetic
    all_day? = is_struct(event.start_time, Date) and not is_struct(event.start_time, DateTime)
    start_dt = step_datetime(event.start_time)
    end_dt = step_datetime(event.end_time) || DateTime.add(start_dt, 30, :minute)
    duration = DateTime.diff(end_dt, start_dt, :second)
    range_start_dt = step_datetime(range_start)
    range_end_dt = step_datetime(range_end)
    exdates_dt = exdates |> Enum.map(&step_datetime/1) |> Enum.reject(&is_nil/1)

    start_dt
    |> occurrence_starts(rule, range_start_dt, range_end_dt, limits)
    |> Stream.reject(&excluded?(&1, exdates_dt))
    |> take_at_most(if limits == :capped, do: @max_occurrences)
    |> Enum.map(&build_occurrence(event, &1, duration, all_day?))
  end

  # The starts the rule makes within the range, in order.
  defp occurrence_starts(start_dt, rule, range_start_dt, range_end_dt, limits) do
    {first_step, max_steps} =
      case limits do
        :capped -> {fast_forward(start_dt, rule, range_start_dt), @max_steps}
        :uncapped -> {start_dt, nil}
      end

    first_step
    |> Stream.iterate(&advance(&1, rule))
    |> take_at_most(rule.count)
    |> take_at_most(max_steps)
    |> Stream.take_while(&before_end?(&1, rule, range_end_dt))
    |> Stream.filter(&in_range?(&1, range_start_dt, range_end_dt))
    |> Stream.filter(&matches_byday?(&1, rule))
  end

  # Moves a series' first step forward by whole periods to just before
  # `range_start`, landing on a step the series makes anyway, so a series that
  # began years ago does not step through every occurrence since. Only a
  # series without `COUNT` can skip ahead: `COUNT` is spent on the steps
  # skipped. Only a fixed period can be skipped arithmetically: DAILY and
  # WEEKLY (with BYDAY, a whole number of weeks keeps to the series' own weeks).
  # MONTHLY and YEARLY step from the first start, which their few steps a year
  # allow.
  #
  # The jump stops at least one full period short of `range_start`, so a
  # daylight-saving offset or a BYDAY day earlier in the landing week cannot
  # put an occurrence inside the range behind it. Days are added on the
  # series' own wall clock, as `advance/2` does.
  defp fast_forward(start_dt, %{count: nil} = rule, range_start_dt) do
    with period when is_integer(period) <- period_days(rule),
         periods when periods > 0 <-
           div(DateTime.diff(range_start_dt, start_dt, :second), period * 86_400) - 1 do
      shift_calendar_days(start_dt, periods * period)
    else
      _no_skip -> start_dt
    end
  end

  defp fast_forward(start_dt, _rule, _range_start_dt), do: start_dt

  defp period_days(%{freq: :daily, interval: interval}) when interval > 0, do: interval
  defp period_days(%{freq: :weekly, interval: interval}) when interval > 0, do: 7 * interval
  defp period_days(_rule), do: nil

  # An all-day series is stepped through as DateTimes at UTC midnight purely
  # for uniform arithmetic, and turned back into dates by `build_occurrence/4`.
  # The instant means nothing: an all-day event's real span depends on the
  # owner's timezone (`Tymeslot.Availability.Events.to_interval/2`).
  defp step_datetime(%DateTime{} = datetime), do: datetime
  defp step_datetime(%Date{} = date), do: DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
  defp step_datetime(nil), do: nil

  defp take_at_most(occurrences, nil), do: occurrences
  defp take_at_most(occurrences, most), do: Stream.take(occurrences, most)

  defp build_occurrence(event, occ_start, duration, true = _all_day?) do
    Map.merge(event, %{
      start_time: DateTime.to_date(occ_start),
      end_time: DateTime.to_date(DateTime.add(occ_start, duration, :second))
    })
  end

  defp build_occurrence(event, occ_start, duration, false = _all_day?) do
    Map.merge(event, %{
      start_time: occ_start,
      end_time: DateTime.add(occ_start, duration, :second)
    })
  end

  defp advance(dt, %{freq: :daily, interval: interval}) do
    shift_calendar_days(dt, interval)
  end

  defp advance(dt, %{freq: :weekly, interval: interval, by_day: nil}) do
    shift_calendar_days(dt, 7 * interval)
  end

  defp advance(dt, %{freq: :weekly, by_day: by_day} = rule) do
    advance_to_next_byday(dt, by_day, rule.interval)
  end

  defp advance(dt, %{freq: :monthly, interval: interval}) do
    new_date = shift_months(DateTime.to_date(dt), interval)
    rebuild_in_zone(dt, new_date)
  end

  defp advance(dt, %{freq: :yearly, interval: interval}) do
    new_date = shift_months(DateTime.to_date(dt), 12 * interval)
    rebuild_in_zone(dt, new_date)
  end

  defp advance_to_next_byday(dt, by_day, interval) do
    current_dow = day_of_week_atom(dt)
    day_numbers = by_day |> Enum.map(&@day_numbers[&1]) |> Enum.sort()
    current_number = @day_numbers[current_dow]

    case Enum.find(day_numbers, &(&1 > current_number)) do
      nil ->
        first_day = List.first(day_numbers)
        days_to_end_of_week = 7 - current_number
        days_from_start = first_day
        skip_weeks = interval - 1
        days_ahead = days_to_end_of_week + days_from_start + skip_weeks * 7
        shift_calendar_days(dt, days_ahead)

      next_number ->
        shift_calendar_days(dt, next_number - current_number)
    end
  end

  # Advances `dt` by a whole number of calendar days while preserving the
  # wall-clock time-of-day in the event's own timezone. Adding the days to the
  # naive datetime (which has no DST) and re-resolving in the zone is what keeps
  # "every day at 15:00" at 15:00 local across a daylight-saving transition —
  # unlike DateTime.add/3, which advances the absolute instant and lets the
  # local time silently drift by an hour after the clocks change.
  defp shift_calendar_days(dt, days) do
    dt
    |> DateTime.to_naive()
    |> NaiveDateTime.add(days, :day)
    |> resolve_in_zone(dt.time_zone)
  end

  # Rebuilds an occurrence at `new_date` keeping `dt`'s wall-clock time-of-day
  # and timezone (monthly/yearly stepping, where the date jumps but the local
  # time and zone are held fixed).
  defp rebuild_in_zone(dt, new_date) do
    new_date
    |> NaiveDateTime.new!(DateTime.to_time(dt))
    |> resolve_in_zone(dt.time_zone)
  end

  # Resolves a naive wall-time into `zone` by the shared DST rule
  # (`DateTimeUtils.resolve_local/3`), falling back to UTC on an unknown zone
  # so an occurrence is never silently lost.
  defp resolve_in_zone(naive, zone) do
    DateTimeUtils.create_datetime_safe(
      NaiveDateTime.to_date(naive),
      NaiveDateTime.to_time(naive),
      zone
    )
  end

  defp shift_months(date, months) do
    total_months = date.year * 12 + (date.month - 1) + months
    year = div(total_months, 12)
    month = rem(total_months, 12) + 1
    day = min(date.day, Date.days_in_month(Date.new!(year, month, 1)))
    Date.new!(year, month, day)
  end

  defp before_end?(dt, rule, range_end) do
    within_range = DateTime.compare(dt, range_end) != :gt

    within_until =
      case rule[:until] do
        nil -> true
        until -> DateTime.compare(dt, until) != :gt
      end

    within_range and within_until
  end

  defp in_range?(dt, range_start, range_end) do
    DateTime.compare(dt, range_start) != :lt and
      DateTime.compare(dt, range_end) != :gt
  end

  defp matches_byday?(_dt, %{by_day: nil}), do: true

  defp matches_byday?(dt, %{by_day: by_day}) do
    day_of_week_atom(dt) in by_day
  end

  defp excluded?(_dt, []), do: false

  defp excluded?(dt, exdates) do
    Enum.any?(exdates, fn exdate ->
      DateTime.compare(DateTime.truncate(dt, :second), DateTime.truncate(exdate, :second)) == :eq
    end)
  end

  defp day_of_week_atom(dt) do
    case Date.day_of_week(DateTime.to_date(dt)) do
      1 -> :monday
      2 -> :tuesday
      3 -> :wednesday
      4 -> :thursday
      5 -> :friday
      6 -> :saturday
      7 -> :sunday
    end
  end
end
