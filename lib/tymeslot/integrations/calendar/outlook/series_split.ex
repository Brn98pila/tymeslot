defmodule Tymeslot.Integrations.Calendar.Outlook.SeriesSplit do
  @moduledoc """
  The two writes that split an Outlook recurring event in two at one of its
  occurrences, for an edit of that occurrence and every one after it (see
  `Recurrence.SeriesSplit`). Pure data: the provider reads the series
  master, and writes what this builds.

  Graph keeps a series' end in its `recurrence.range`, read as local dates in
  the zone the series was created in (`originalStartTimeZone`):

    * **The tail** is created as a new event: the master's own fields, with
      `start` and `end` at the slot's wall clock in that zone, labelled with
      it, and the length the master has; the master's pattern; and its range
      from the slot's date on (`startDate`), a `numbered` range with its
      `numberOfOccurrences` less the occurrences before the slot, an
      `endDate` or `noEnd` range as it was. The edit is then applied to it by
      `Outlook.SeriesPatch` as an edit of every occurrence, so a move, a new
      rule and new fields land on the tail alone.
    * **The head** is the master patched with its `recurrence` alone: the
      same pattern, and an `endDate` range ending on the day before the
      slot's date.

  The tail is built from the master as `Outlook.CreatableEvent` makes any
  event creatable: its writable fields only, without what Graph assigns or
  manages itself and without the series' online meeting, since creating an
  event with one asks Teams for a new meeting. The join details the
  organiser sees in the body are copied with it, and lead to the original
  meeting, which the head keeps.

  Occurrences edited or deleted on their own are not in the master's
  `recurrence`, so these bodies make the tail's occurrences all plain, and
  Graph drops the master's own exceptions from the slot on once its range
  ends before them. The provider carries them to the tail once it is
  written (`Outlook.SeriesExceptions`).
  """

  alias Tymeslot.Integrations.Calendar.Outlook.CreatableEvent
  alias Tymeslot.Integrations.Calendar.Outlook.SeriesPatch
  alias Tymeslot.Integrations.Calendar.Recurrence.SeriesMove
  alias Tymeslot.Integrations.Calendar.Recurrence.SeriesSplit

  @typedoc "The tail's body for a create, and the master's for a patch."
  @type halves :: %{tail: map(), head: map()}

  @doc """
  The halves `master`, the series master as Graph returned it (in UTC), is
  split into at `edit.slot` (see `Recurrence.SeriesSplit.slot/0`), with the
  edit (see `Recurrence.SeriesMove.edit/0`) applied to the tail.

  `:first_occurrence` when nothing of the series comes before the slot: the
  edit is of every occurrence, and is written as one.
  """
  @spec build(map(), SeriesMove.edit()) :: {:ok, halves()} | :first_occurrence | {:error, term()}
  def build(master, %{slot: slot} = edit) do
    with {:ok, timing, {zone, label}} <- SeriesPatch.master_timing(master),
         {:ok, recurrence} <- find_recurrence(master),
         {:ok, slot} <- SeriesSplit.slot_wall(slot, timing, zone),
         :ok <- ensure_occurrences_before(recurrence, timing, slot, zone),
         {:ok, range} <- tail_range(recurrence, timing, slot, zone),
         tail = tail(master, timing, slot, label, %{recurrence | "range" => range}),
         {:ok, patch} <- SeriesPatch.build(tail, edit) do
      {:ok,
       %{
         tail: tail |> Map.merge(patch) |> Map.delete("originalStartTimeZone"),
         head: %{"recurrence" => head_recurrence(recurrence, slot)}
       }}
    end
  end

  defp find_recurrence(%{"recurrence" => %{"pattern" => %{}, "range" => %{}} = recurrence}),
    do: {:ok, recurrence}

  defp find_recurrence(_master), do: {:error, :not_recurring}

  # --- The ranges ---

  defp tail_range(%{"range" => range} = recurrence, timing, slot, zone) do
    from_slot = Map.put(range, "startDate", Date.to_iso8601(date_of(slot)))

    case range do
      %{"type" => "numbered", "numberOfOccurrences" => total} when is_integer(total) ->
        with {:ok, before} <- count_before(recurrence, timing, slot, zone),
             do: {:ok, Map.put(from_slot, "numberOfOccurrences", max(total - before, 1))}

      _end_date_or_none ->
        {:ok, from_slot}
    end
  end

  # Graph counts only the dates its pattern makes, so a master whose start is
  # off the pattern (a Monday-and-Wednesday series created on a Tuesday
  # through the API) does not have that start as an occurrence: its first
  # occurrence is the pattern's first date, and `numberOfOccurrences` does
  # not include the start. RFC 5545, which the count follows, always counts
  # it, so it comes off again here.
  defp count_before(
         %{"pattern" => pattern, "range" => range},
         {start, _finish} = timing,
         slot,
         zone
       ) do
    with {:ok, rule} <- rule(pattern, range),
         {:ok, count} <- SeriesSplit.count_before(rule, timing, slot, zone) do
      {:ok, if(on_pattern?(pattern, start), do: count, else: count - 1)}
    end
  end

  # Of the patterns the count follows (daily and weekly; see
  # `RecurrenceExpander.countable?/1`), only a weekly one's days can miss the
  # master's start.
  defp on_pattern?(%{"type" => "weekly", "daysOfWeek" => days}, start)
       when is_list(days) and days != [] do
    weekday = start |> date_of() |> Calendar.strftime("%A") |> String.downcase()
    weekday in Enum.map(days, &String.downcase/1)
  end

  defp on_pattern?(_pattern, _start), do: true

  defp rule(pattern, range) do
    case SeriesPatch.pattern_rule(pattern, range) do
      {:ok, rule} -> {:ok, rule}
      {:error, _pinned} -> {:error, :unsupported_rule}
    end
  end

  # A slot with no pattern date before it is the series' first occurrence,
  # even when the master's start, off the pattern, comes earlier. A pattern
  # the count cannot follow is judged by the master's start alone.
  defp ensure_occurrences_before(recurrence, timing, slot, zone) do
    with :ok <- SeriesSplit.ensure_occurrences_before(timing, slot) do
      case count_before(recurrence, timing, slot, zone) do
        {:ok, 0} -> :first_occurrence
        _some_or_uncountable -> :ok
      end
    end
  end

  defp head_recurrence(%{"range" => range} = recurrence, slot) do
    ended =
      range
      |> Map.delete("numberOfOccurrences")
      |> Map.merge(%{
        "type" => "endDate",
        "endDate" => slot |> date_of() |> Date.add(-1) |> Date.to_iso8601()
      })

    %{recurrence | "range" => ended}
  end

  # --- The tail ---

  # `originalStartTimeZone` is what `SeriesPatch` reads the tail's zone from;
  # it is not written.
  defp tail(master, timing, slot, label, recurrence) do
    master
    |> CreatableEvent.from_event()
    |> CreatableEvent.put_timing(SeriesSplit.at_slot(timing, slot), label)
    |> Map.merge(%{"recurrence" => recurrence, "originalStartTimeZone" => label})
  end

  defp date_of(%Date{} = date), do: date
  defp date_of(wall), do: NaiveDateTime.to_date(wall)
end
