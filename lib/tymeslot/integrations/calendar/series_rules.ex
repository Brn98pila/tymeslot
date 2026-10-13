defmodule Tymeslot.Integrations.Calendar.SeriesRules do
  @moduledoc """
  The repeat rules of the Google and Outlook series an integration's cache
  holds occurrences of.

  Both providers list a series as its single occurrences, each naming its
  master in `recurring_event_id` and none saying how the series repeats. The
  rule lives on the master, so it is kept apart (`calendar_series_rules`, one
  row per series) and copied onto every occurrence as it is cached
  (`stamp/2`), which is what lets the grid show the pattern and edit it.

  ## What the copy is for

  A stamped rule describes the series an occurrence belongs to; it never
  makes the occurrence one. Nothing expands a cached row's rule: the cache
  holds every occurrence already, and the availability read drops the rule
  (`ProviderCalendarEventSchema`). A write to one occurrence sends no rule
  (`Tymeslot.CalendarGrid.SeriesEdit`).

  CalDAV occurrences name no master and carry their resource's rule already,
  so none of this applies to them.
  """

  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Integrations.Calendar.SeriesRuleQueries

  @doc """
  Gives every occurrence in `calendar_events` that names a master with a
  stored rule, and carries no rule of its own, that rule. One read for the
  batch.
  """
  @spec stamp(integer(), [CalendarEvent.t()]) :: [CalendarEvent.t()]
  def stamp(integration_id, calendar_events) do
    rules =
      SeriesRuleQueries.list_by_master(integration_id, master_ids(calendar_events))

    Enum.map(calendar_events, fn
      %{recurrence_rule: nil, recurring_event_id: master_id} = event
      when is_map_key(rules, master_id) ->
        %{event | recurrence_rule: Map.fetch!(rules, master_id).rule}

      event ->
        event
    end)
  end

  @doc """
  Forgets the rules of the series the integration's cache no longer holds an
  occurrence of, once occurrences have been deleted from it.
  """
  @spec forget_orphans(integer()) :: :ok
  def forget_orphans(integration_id) do
    SeriesRuleQueries.delete_orphans(integration_id)
    :ok
  end

  @doc """
  Gives each event in `events` (or the one event) that names a master with a
  stored rule its series' first start, as `:series_start`, which is what a
  `COUNT` is counted from (`Tymeslot.CalendarGrid.EventVideoRoomTimes`). One
  read for the list; an event without one is returned as it was.
  """
  @spec with_series_start([map()]) :: [map()]
  @spec with_series_start(map()) :: map()
  def with_series_start(events) when is_list(events) do
    starts =
      events
      |> Enum.group_by(&Map.get(&1, :calendar_integration_id))
      |> Enum.flat_map(fn
        {nil, _not_cached} -> []
        {integration_id, of_integration} -> series_starts(integration_id, of_integration)
      end)
      |> Map.new()

    Enum.map(events, fn event ->
      key = {Map.get(event, :calendar_integration_id), Map.get(event, :recurring_event_id)}

      case Map.get(starts, key) do
        %DateTime{} = series_start -> Map.put(event, :series_start, series_start)
        nil -> event
      end
    end)
  end

  def with_series_start(event), do: [event] |> with_series_start() |> hd()

  defp series_starts(integration_id, events) do
    integration_id
    |> SeriesRuleQueries.list_by_master(master_ids(events))
    |> Enum.map(fn {master_id, row} -> {{integration_id, master_id}, row.master_start} end)
  end

  @doc "The distinct masters `calendar_events` name."
  @spec master_ids([map()]) :: [String.t()]
  def master_ids(calendar_events) do
    calendar_events
    |> Enum.map(&Map.get(&1, :recurring_event_id))
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end
end
