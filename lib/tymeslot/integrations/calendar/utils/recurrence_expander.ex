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

  require Logger

  @weekdays %{"MO" => 1, "TU" => 2, "WE" => 3, "TH" => 4, "FR" => 5, "SA" => 6, "SU" => 7}

  # Safety cap: `expand/4` never returns more than this many occurrences of
  # one event, however wide the range. It counts occurrences inside the range,
  # not steps from the series' first start, so a series that has run for years
  # still shows in this week's range.
  @max_occurrences 500

  # Runaway guard: `expand/4` stops after this many periods (days, weeks,
  # months or years of the rule's FREQ) whatever they yield, so a rule that
  # never reaches the range cannot spin for ever. A series without `COUNT` is
  # first fast-forwarded to the range (`periods_to_skip/3`), so this only binds
  # on a series with a `COUNT` that has run for a very long time.
  @max_steps 100_000

  # The rule parts `expand/4` follows (RFC 5545 §3.3.10). Any other part
  # (BYWEEKNO, BYYEARDAY, BYHOUR, ...) is ignored with a warning, so the
  # series may then miss occurrences.
  @supported_parts ~w(FREQ INTERVAL COUNT UNTIL BYDAY BYMONTHDAY BYMONTH BYSETPOS WKST)

  # The rule parts a series split counts by (see `countable?/1`).
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
        warn_unsupported(rule, rrule)
        generate_occurrences(event, rule, range_start, range_end, exdates, :capped)

      :error ->
        # Fail-open: return the original event rather than silently dropping it
        [event]
    end
  end

  def expand(event, _range_start, _range_end, _opts), do: [event]

  defp warn_unsupported(%{unsupported: []}, _rrule), do: :ok

  defp warn_unsupported(%{unsupported: parts}, rrule) do
    Logger.warning(
      "Recurrence rule parts #{Enum.join(parts, ", ")} are not supported and were ignored; " <>
        "the series may miss occurrences",
      rrule: rrule
    )
  end

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
  Whether a series split may take `count_before/3` off `rule`'s `COUNT`:
  whether `rule` repeats only by `FREQ`, `INTERVAL`, `COUNT`, `UNTIL`, `WKST`
  and a `BYDAY` without ordinals. `expand/4` and `count_before/3` also follow
  `BYMONTHDAY`, `BYMONTH`, `BYSETPOS` and an ordinal `BYDAY` such as `2MO`,
  but a split of a `COUNT` over those is not accepted, so it stays refused
  rather than ending on another date than the series did.

  A rule repeating on several days every few weeks is countable only when
  its week start (`WKST`) makes no difference.
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

  Supported properties: FREQ, INTERVAL, UNTIL, COUNT, BYDAY (with ordinals),
  BYMONTHDAY, BYMONTH, BYSETPOS and WKST. The names of any other parts are
  listed under `:unsupported`. Returns `{:ok, map()}`, or `:error` for a rule
  without a known FREQ or with an INTERVAL below 1.
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

    # RFC 5545 requires a positive INTERVAL. A rule that never moves forward
    # (`INTERVAL=0`) or moves backwards is unreadable like any other invalid
    # rule, so its event is shown once, as it is.
    with {:ok, freq} <- parse_freq(parts["FREQ"]),
         interval when interval > 0 <- parse_int(parts["INTERVAL"], 1) do
      {:ok,
       Map.merge(
         %{
           freq: freq,
           interval: interval,
           until: parse_until(parts["UNTIL"]),
           count: parse_int(parts["COUNT"], nil),
           unsupported:
             parts |> Map.keys() |> Enum.reject(&(&1 in @supported_parts)) |> Enum.sort()
         },
         parse_by_parts(parts)
       )}
    else
      _invalid -> :error
    end
  end

  defp parse_by_parts(parts) do
    %{
      by_day: parse_byday(parts["BYDAY"]),
      by_month_day: parse_int_list(parts["BYMONTHDAY"], -31..31),
      by_month: parse_int_list(parts["BYMONTH"], 1..12),
      by_set_pos: parse_int_list(parts["BYSETPOS"], -366..366),
      week_start: Map.get(@weekdays, String.upcase(parts["WKST"] || ""), 1)
    }
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

  # Each BYDAY entry is `{ordinal, weekday}`, with `ordinal` nil for every
  # such weekday (`MO`) and counted from the end when negative (`-1FR`).
  defp parse_byday(nil), do: nil

  defp parse_byday(str) do
    days =
      str
      |> String.split(",")
      |> Enum.flat_map(fn day_str ->
        case Regex.run(
               ~r/^([+-]?\d{1,2})?([A-Z]{2})$/,
               day_str |> String.trim() |> String.upcase()
             ) do
          [_match, ordinal, code] when is_map_key(@weekdays, code) ->
            parse_ordinal_day(ordinal, Map.fetch!(@weekdays, code))

          _other ->
            []
        end
      end)

    if days == [], do: nil, else: days
  end

  defp parse_ordinal_day("", weekday), do: [{nil, weekday}]

  defp parse_ordinal_day(ordinal, weekday) do
    case Integer.parse(ordinal) do
      {n, ""} when n != 0 -> [{n, weekday}]
      _invalid -> []
    end
  end

  defp parse_int_list(nil, _valid), do: nil

  defp parse_int_list(str, valid) do
    values =
      str
      |> String.split(",")
      |> Enum.flat_map(fn value ->
        case Integer.parse(String.trim(value)) do
          {n, ""} when n != 0 -> if n in valid, do: [n], else: []
          _invalid -> []
        end
      end)

    if values == [], do: nil, else: values
  end

  # --- Private: Occurrence generation ---

  # `:capped` (for `expand/4`) fast-forwards to the range where it can, and
  # bounds the periods stepped by `@max_steps` and the occurrences returned by
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

  # The starts the rule makes within the range, in order. The rule is expanded
  # period by period (RFC 5545 §3.3.10): each period of FREQ yields the dates
  # its BYxxx parts select, BYSETPOS picks among them, and every date takes
  # the first start's wall-clock time in its zone. COUNT counts the starts so
  # made from the first start, before the range and EXDATE are applied.
  defp occurrence_starts(start_dt, rule, range_start_dt, range_end_dt, limits) do
    first_date = DateTime.to_date(start_dt)
    first_period = period_start(first_date, rule)

    {skip, max_periods} =
      case limits do
        :capped -> {periods_to_skip(first_period, rule, range_start_dt), @max_steps}
        :uncapped -> {0, nil}
      end

    last_date = last_period_date(rule, range_end_dt)

    skip
    |> Stream.iterate(&(&1 + 1))
    |> Stream.map(&nth_period(first_period, rule, &1))
    |> take_at_most(max_periods)
    |> Stream.take_while(&(Date.compare(&1, last_date) != :gt))
    |> Stream.flat_map(&period_dates(&1, rule, first_date))
    |> Stream.reject(&(Date.compare(&1, first_date) == :lt))
    |> Stream.map(&if(&1 == first_date, do: start_dt, else: rebuild_in_zone(start_dt, &1)))
    |> take_at_most(rule.count)
    |> Stream.take_while(&before_end?(&1, rule, range_end_dt))
    |> Stream.filter(&in_range?(&1, range_start_dt, range_end_dt))
  end

  # The first day of the period of FREQ holding `date`.
  defp period_start(date, %{freq: :daily}), do: date

  defp period_start(date, %{freq: :weekly, week_start: week_start}),
    do: Date.add(date, -rem(Date.day_of_week(date) - week_start + 7, 7))

  defp period_start(date, %{freq: :monthly}), do: Date.beginning_of_month(date)
  defp period_start(date, %{freq: :yearly}), do: Date.new!(date.year, 1, 1)

  defp nth_period(first, %{freq: :daily, interval: interval}, n),
    do: Date.add(first, n * interval)

  defp nth_period(first, %{freq: :weekly, interval: interval}, n),
    do: Date.add(first, 7 * n * interval)

  defp nth_period(first, %{freq: :monthly, interval: interval}, n),
    do: shift_months(first, n * interval)

  defp nth_period(first, %{freq: :yearly, interval: interval}, n),
    do: shift_months(first, 12 * n * interval)

  # How many periods a series can skip to come to just before `range_start`,
  # so a series that began years ago does not step through every occurrence
  # since. Only a series without `COUNT` can skip ahead: `COUNT` is spent on
  # the periods skipped. The skip stops a full period short of the range, so
  # an occurrence that the range's zone puts on another day is not passed.
  defp periods_to_skip(first_period, %{count: nil, interval: interval} = rule, range_start_dt) do
    max(
      div(periods_between(first_period, DateTime.to_date(range_start_dt), rule), interval) - 1,
      0
    )
  end

  defp periods_to_skip(_first_period, _rule, _range_start_dt), do: 0

  defp periods_between(from, to, %{freq: :daily}), do: Date.diff(to, from)
  defp periods_between(from, to, %{freq: :weekly}), do: div(Date.diff(to, from), 7)

  defp periods_between(from, to, %{freq: :monthly}),
    do: to.year * 12 + to.month - (from.year * 12 + from.month)

  defp periods_between(from, to, %{freq: :yearly}), do: to.year - from.year

  # No period starting after this date can hold a start before the range's end
  # or UNTIL. The day's slack covers a zone that puts that instant on the
  # next day.
  defp last_period_date(rule, range_end_dt) do
    [range_end_dt, rule.until]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&Date.add(DateTime.to_date(&1), 1))
    |> Enum.min(Date)
  end

  # The dates one period yields, in order.
  defp period_dates(period, rule, first_date) do
    period
    |> candidate_dates(rule, first_date)
    |> Enum.uniq()
    |> Enum.sort(Date)
    |> select_set_pos(rule.by_set_pos)
  end

  # BYDAY, BYMONTHDAY and BYMONTH limit a DAILY rule's days, and BYMONTH a
  # WEEKLY rule's; an ordinal in BYDAY means nothing for either.
  defp candidate_dates(day, %{freq: :daily} = rule, _first_date) do
    if in_months?(day, rule) and on_month_days?(day, rule) and on_weekdays?(day, rule, nil),
      do: [day],
      else: []
  end

  defp candidate_dates(week, %{freq: :weekly} = rule, first_date) do
    weekdays =
      if rule.by_day,
        do: Enum.map(rule.by_day, &elem(&1, 1)),
        else: [Date.day_of_week(first_date)]

    weekdays
    |> Enum.map(&Date.add(week, rem(&1 - rule.week_start + 7, 7)))
    |> Enum.filter(&in_months?(&1, rule))
  end

  defp candidate_dates(month, %{freq: :monthly} = rule, first_date) do
    if in_months?(month, rule), do: month_dates(month, rule, first_date), else: []
  end

  # A YEARLY rule's BYDAY ordinals count within each BYMONTH month when there
  # is one, and within the year otherwise.
  defp candidate_dates(year, %{freq: :yearly, by_month: months} = rule, first_date)
       when is_list(months) do
    months
    |> Enum.sort()
    |> Enum.flat_map(&month_dates(Date.new!(year.year, &1, 1), rule, first_date))
  end

  defp candidate_dates(year, %{freq: :yearly} = rule, first_date) do
    if rule.by_month_day || rule.by_day do
      year_end = Date.new!(year.year, 12, 31)

      Enum.filter(
        Date.range(year, year_end),
        &(on_month_days?(&1, rule) and on_weekdays?(&1, rule, {year, year_end}))
      )
    else
      [clamped_date(year.year, first_date.month, first_date.day)]
    end
  end

  # The days of a month a MONTHLY rule (or a YEARLY one by BYMONTH) selects.
  # Without BYMONTHDAY or BYDAY that is the first start's day, moved back to
  # the month's last day when the month is shorter.
  defp month_dates(month, rule, first_date) do
    if rule.by_month_day || rule.by_day do
      month_end = Date.end_of_month(month)

      Enum.filter(
        Date.range(month, month_end),
        &(on_month_days?(&1, rule) and on_weekdays?(&1, rule, {month, month_end}))
      )
    else
      [clamped_date(month.year, month.month, first_date.day)]
    end
  end

  defp clamped_date(year, month, day),
    do: Date.new!(year, month, min(day, Date.days_in_month(Date.new!(year, month, 1))))

  defp in_months?(_date, %{by_month: nil}), do: true
  defp in_months?(date, %{by_month: months}), do: date.month in months

  defp on_month_days?(_date, %{by_month_day: nil}), do: true

  defp on_month_days?(date, %{by_month_day: days}) do
    from_end = date.day - Date.days_in_month(date) - 1
    Enum.any?(days, &(&1 == date.day or &1 == from_end))
  end

  defp on_weekdays?(_date, %{by_day: nil}, _scope), do: true

  defp on_weekdays?(date, %{by_day: by_day}, scope) do
    weekday = Date.day_of_week(date)

    Enum.any?(by_day, fn {ordinal, day} ->
      day == weekday and nth_in_scope?(date, ordinal, scope)
    end)
  end

  # Whether `date` is the `ordinal`th of its weekday within `scope`, the
  # month or year it is counted in; a negative ordinal counts from the end.
  defp nth_in_scope?(_date, nil, _scope), do: true
  defp nth_in_scope?(_date, _ordinal, nil), do: true

  defp nth_in_scope?(date, ordinal, {first, _last}) when ordinal > 0,
    do: div(Date.diff(date, first), 7) + 1 == ordinal

  defp nth_in_scope?(date, ordinal, {_first, last}),
    do: -(div(Date.diff(last, date), 7) + 1) == ordinal

  defp select_set_pos(dates, nil), do: dates

  defp select_set_pos(dates, positions) do
    count = length(dates)

    positions
    |> Enum.flat_map(fn
      position when position > 0 and position <= count -> [Enum.at(dates, position - 1)]
      position when position < 0 and -position <= count -> [Enum.at(dates, position)]
      _out_of_set -> []
    end)
    |> Enum.uniq()
    |> Enum.sort(Date)
  end

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

  # Rebuilds an occurrence at `new_date` keeping `dt`'s wall-clock time-of-day
  # and timezone. Re-resolving the wall time in the zone on each date is what
  # keeps "every day at 15:00" at 15:00 local across a daylight-saving
  # change, where adding a period to the instant would drift by an hour.
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

  defp excluded?(_dt, []), do: false

  defp excluded?(dt, exdates) do
    Enum.any?(exdates, fn exdate ->
      DateTime.compare(DateTime.truncate(dt, :second), DateTime.truncate(exdate, :second)) == :eq
    end)
  end
end
