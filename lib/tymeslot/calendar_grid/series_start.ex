defmodule Tymeslot.CalendarGrid.SeriesStart do
  @moduledoc """
  Where a series begins: the start of its first occurrence, which an edit of
  the whole series writes its repeat pattern against.

  A repeat pattern is anchored to a start (`Recurrence.Pattern`): a monthly
  series "on the start's day" names no day, a weekly one always includes the
  start's weekday. A rule written to a whole series is read against the
  series' own first start, never the start of the occurrence it was edited
  from, so that is the start a whole-series edit is built from.

  Each provider keeps it differently:

    * Google and Outlook: the master's start, cached beside the series' rule
      (`SeriesRules.with_series_start/1`).
    * The CalDAV family: the master `VEVENT`'s `DTSTART`, in the document
      cached on every occurrence.
    * An event with no series: its own start.

  A series whose first start is not known (a Google or Outlook series whose
  master has not been read) answers `nil`.
  """

  alias Tymeslot.CalendarGrid.Occurrence
  alias Tymeslot.Integrations.Calendar.ICalParser
  alias Tymeslot.Integrations.Calendar.SeriesRules

  @doc """
  The first start of the series `event` belongs to: a `Date` for an all-day
  series, a UTC `DateTime` otherwise, or `nil` when it is not known.
  """
  @spec of(map()) :: Date.t() | DateTime.t() | nil
  def of(event) do
    case Occurrence.series_family(event) do
      :single -> own_start(event)
      :caldav -> event |> Occurrence.cached_row() |> caldav_start()
      :provider_ids -> provider_start(event)
      :unsupported -> nil
    end
  end

  # A Google or Outlook master's own row carries the rule and is its first
  # start; an occurrence names its master in `recurring_event_id`.
  defp provider_start(event) do
    if is_nil(Map.get(event, :recurring_event_id)) do
      own_start(event)
    else
      case SeriesRules.with_series_start(event) do
        %{series_start: %DateTime{} = start} -> fit(start, event)
        _not_read -> nil
      end
    end
  end

  defp caldav_start(%{raw_ical: document} = row) when is_binary(document) do
    with {:ok, events} <- ICalParser.parse(document),
         %{start_time: start} <- Enum.find(events, &master?/1) do
      fit(start, row)
    else
      _no_master -> nil
    end
  end

  defp caldav_start(_row), do: nil

  defp master?(parsed),
    do: is_binary(parsed[:recurrence_rule]) and is_nil(parsed[:recurrence_id])

  defp own_start(%{all_day: true, start_date: %Date{} = date}), do: date
  defp own_start(%{start_at: %DateTime{} = start} = event), do: fit(start, event)
  defp own_start(_event), do: nil

  # An all-day series starts on a day; a master read as midnight UTC is
  # that day.
  defp fit(%DateTime{} = start, %{all_day: true}), do: DateTime.to_date(start)
  defp fit(%Date{} = start, %{all_day: true}), do: start
  defp fit(%DateTime{} = start, _event), do: DateTime.shift_zone!(start, "Etc/UTC")
  defp fit(%Date{} = start, _event), do: DateTime.new!(start, ~T[00:00:00], "Etc/UTC")
end
