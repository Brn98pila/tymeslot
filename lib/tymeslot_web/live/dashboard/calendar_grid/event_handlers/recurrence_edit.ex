defmodule TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.RecurrenceEdit do
  @moduledoc """
  The repeat editor in an event's details: a pattern is staged while the
  organiser builds it, and written once, when they save it.

  ## Staged, then saved

  Each change of the editor's controls is composed into a rule and kept in
  the `:recurrence_edit` assign (`Shared.recurrence_edit/1`), not written:
  a pattern such as "monthly on the second Tuesday, six times" takes
  several controls, and writing each one would ask for a scope and rewrite
  the series every time. "Save repeat" writes the staged rule, through one
  scope prompt for a series; "Discard changes" drops it.

  ## Anchored to the series' start

  A rule written to a whole series is read from the series' first start, so
  the editor shows and builds the pattern from that start
  (`Shared.series_anchor/3`). "This and following events" starts a new
  series at the opened occurrence, so the same choices are built again
  from the occurrence's start, which may name another day (monthly "on day
  30" is "on day 14" from a 14 October occurrence). The scope prompt shows
  each scope's pattern as it will be written, and leaves out a scope whose
  calendar would refuse it (`CalendarGrid.repeat_refusal/4`) or whose
  series start is not known.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 3]

  alias Tymeslot.CalendarGrid
  alias Tymeslot.CalendarGrid.SeriesEdit
  alias Tymeslot.Integrations.Calendar.Recurrence.Pattern
  alias TymeslotWeb.Dashboard.CalendarGrid.EditWorkflow
  alias TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.Shared
  alias TymeslotWeb.Dashboard.CalendarGrid.Helpers
  alias TymeslotWeb.Dashboard.CalendarGrid.Modals.RecurrenceEditor

  @doc "Stages the pattern the editor's controls now describe."
  @spec handle_update_event_recurrence(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_update_event_recurrence(params, socket) do
    with %{} = event <- socket.assigns.selected_event,
         %{} = edit <- edit_for(socket, event) do
      stage(socket, event, edit, params)
    else
      _no_editor -> {:noreply, socket}
    end
  end

  @doc "Writes the staged pattern: at once for one event, through the scope prompt for a series."
  @spec handle_save_event_recurrence(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_save_event_recurrence(_params, socket) do
    event = socket.assigns.selected_event

    case event && Shared.recurrence_draft(event, socket.assigns[:recurrence_edit]) do
      %{} = draft -> save(socket, event, draft)
      nil -> {:noreply, socket}
    end
  end

  @doc "Drops the staged pattern, so the editor shows the event's own again."
  @spec handle_discard_event_recurrence(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_discard_event_recurrence(_params, socket),
    do: {:noreply, clear_draft(socket)}

  @doc "Forgets a staged pattern once its write has been sent."
  @spec clear_draft(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def clear_draft(socket) do
    case socket.assigns[:recurrence_edit] do
      %{} = edit -> assign(socket, :recurrence_edit, %{edit | draft: nil})
      nil -> socket
    end
  end

  # The editor is shown only for a calendar the grid writes rules to, whose
  # event was opened with its series' start read (`Shared.recurrence_edit/1`).
  defp edit_for(socket, event) do
    case socket.assigns[:recurrence_edit] do
      %{event_id: id} = edit when id == event.id -> edit
      _other -> Shared.recurrence_edit(event)
    end
  end

  defp stage(socket, event, edit, params) do
    {anchor, _known?} = Shared.series_anchor(event, edit, socket.assigns.user_timezone)

    case Shared.compose_recurrence_rule(params, context(event, anchor, socket)) do
      {:error, :until_before_start} = error ->
        Shared.flash_guard_error(socket, error)

      rule ->
        # By meaning: a rule another calendar wrote (an UNTIL as a date, days
        # in another order) is not a change by being read back.
        draft =
          if Pattern.equivalent?(rule, event.recurrence_rule, anchor),
            do: nil,
            else: %{params: params, rule: rule}

        {:noreply, assign(socket, :recurrence_edit, %{edit | draft: draft})}
    end
  end

  defp context(event, anchor, socket) do
    %{
      all_day: Map.get(event, :all_day, false),
      start_date: date_of(anchor),
      timezone: Shared.recurrence_timezone(event, socket.assigns.user_timezone),
      rule: event.recurrence_rule
    }
  end

  defp save(socket, event, draft) do
    with :ok <- EditWorkflow.assert_event_writable(socket, event),
         :ok <- Shared.check_seat_lock(socket, event),
         :ok <- Shared.check_edit_rate_limit(socket) do
      if EditWorkflow.series_edit?(event),
        do: prompt_series(socket, event, draft),
        else: write_single(socket, event, draft.rule)
    else
      {:error, reason} = error when reason in [:unauthorized, :read_only, :group_booking] ->
        Shared.flash_guard_error(socket, error)

      {:error, :rate_limited, _message} = error ->
        Shared.flash_guard_error(socket, error)
    end
  end

  # A single event given a rule becomes a series, which a CalDAV calendar
  # stores in the event's own zone so it keeps its local time across DST.
  defp write_single(socket, event, rule) do
    timezone = Shared.recurrence_timezone(event, socket.assigns.user_timezone)
    start_date = event |> Shared.recurrence_start(socket.assigns.user_timezone) |> date_of()

    case CalendarGrid.repeat_refusal(Map.get(event, :provider), rule, start_date, timezone) do
      nil ->
        socket =
          socket
          |> clear_draft()
          |> show_optimistic(event, rule)
          |> EditWorkflow.update_event_async(event, %{recurrence_rule: rule}, timezone: timezone)

        send(self(), {:flash, {:info, dgettext("dashboard_calendar_events", "Changes saved.")}})
        {:noreply, socket}

      reason ->
        send(self(), {:flash, {:error, refusal_message(reason)}})
        {:noreply, socket}
    end
  end

  # A series' repeat rule can be changed, never removed, from the grid: the
  # rule is what makes the events one series, and removing it from some of
  # them is not something any scope can write.
  defp prompt_series(socket, _event, %{rule: nil}) do
    send(
      self(),
      {:flash,
       {:error,
        dgettext(
          "dashboard_calendar_events",
          "That change cannot be made to the events you chose. A repeat rule can only be changed for all events, or this and following events, and cannot be removed here."
        )}}
    )

    {:noreply, socket}
  end

  defp prompt_series(socket, event, draft) do
    scopes = scope_rules(socket, event, draft)

    case Enum.filter(scopes, &is_nil(&1.refusal)) do
      [] ->
        reason = scopes |> Enum.map(& &1.refusal) |> Enum.find(& &1)
        send(self(), {:flash, {:error, refusal_message(reason)}})
        {:noreply, socket}

      [first | _rest] ->
        prompt = %{
          kind: :recurrence_rule,
          event: event,
          optimistic_event: %{event | recurrence_rule: first.rule},
          recurrence_rule: first.rule,
          scope_rules: scopes,
          # The zone the editor ended the rule's UNTIL day in, which the
          # series' writers read the end date back in.
          until_timezone: Shared.recurrence_timezone(event, socket.assigns.user_timezone),
          original_event: event,
          following_notes: following_notes(event, scopes)
        }

        {:noreply,
         socket
         |> show_optimistic(event, first.rule)
         |> assign(:recurrence_prompt, prompt)}
    end
  end

  # What each scope writes, in the order the prompt lists them: from the
  # opened occurrence on, built from its own start, then the whole series,
  # built from the series' first start when that is known.
  defp scope_rules(socket, event, draft) do
    tz = socket.assigns.user_timezone
    edit = socket.assigns[:recurrence_edit]
    occurrence = Shared.recurrence_start(event, tz)
    {series_start, known?} = Shared.series_anchor(event, edit, tz)

    following =
      case Shared.compose_recurrence_rule(draft.params, context(event, occurrence, socket)) do
        {:error, :until_before_start} -> nil
        rule -> scope_rule(:following, rule, occurrence, event, socket)
      end

    all = if known?, do: scope_rule(:all, draft.rule, series_start, event, socket)

    Enum.reject([following, all], &is_nil/1)
  end

  defp scope_rule(scope, rule, start, event, socket) do
    timezone = Shared.recurrence_timezone(event, socket.assigns.user_timezone)

    %{
      scope: scope,
      rule: rule,
      summary: RecurrenceEditor.summary(rule, start),
      refusal:
        CalendarGrid.repeat_refusal(Map.get(event, :provider), rule, date_of(start), timezone)
    }
  end

  defp following_notes(event, scopes) do
    case Enum.find(scopes, &(&1.scope == :following)) do
      %{rule: rule} -> SeriesEdit.following_notes(event, %{recurrence_rule: rule})
      nil -> []
    end
  end

  defp show_optimistic(socket, event, rule) do
    optimistic = %{event | recurrence_rule: rule}

    socket
    |> assign(:selected_event, optimistic)
    |> assign(:events, Shared.replace_event(socket.assigns.events, event.id, optimistic))
    |> Helpers.precompute_derived()
  end

  @doc "What the organiser is told when a calendar refuses a repeat rule."
  @spec refusal_message(atom()) :: String.t()
  def refusal_message(:day_missing_in_some_months), do: EditWorkflow.month_end_refused_message()
  def refusal_message(_reason), do: EditWorkflow.rule_not_supported_by_outlook_message()

  defp date_of(%DateTime{} = at), do: DateTime.to_date(at)
  defp date_of(%Date{} = date), do: date
end
