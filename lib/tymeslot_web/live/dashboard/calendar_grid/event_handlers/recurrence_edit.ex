defmodule TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.RecurrenceEdit do
  @moduledoc """
  The repeat editor in an event's details: a pattern is staged while the
  organiser builds it, and written once, when they save it.

  ## Staged, then saved

  Each change of the editor's controls is kept in the `:recurrence_edit`
  assign (`Shared.recurrence_edit/1`), not written: a pattern such as
  "monthly on the second Tuesday, six times" takes several controls, and
  writing each one would ask for a scope and rewrite the series every time.
  "Save repeat" writes the staged pattern, through one scope prompt for a
  series; "Discard changes" drops it. What is staged is the editor's fields,
  composed into a rule again whenever it is shown or saved
  (`draft_rule/4`), so a start that moves under it (a one-off moved to
  another day) takes the pattern with it.

  ## Anchored to the series' start

  A rule written to a whole series is read from the series' first start, so
  the editor shows and builds the pattern from that start
  (`Shared.series_anchor/3`). "This and following events" splits the series
  where the series put the opened occurrence, its original start
  (`CalendarGrid.occurrence_slot/1`), whether or not it was moved on its
  own since, and starts a new series there; so the same fields are built
  again from that start, which may name another day (monthly "on day 30"
  is "on day 14" from a 14 October occurrence). A `COUNT` there counts what
  is left of the series: the occurrences before the split stay, and are
  taken off it.

  The scope prompt shows each scope's pattern as it will be written. A
  scope whose calendar would refuse its rule (`CalendarGrid.repeat_refusal/4`)
  is listed with the reason, and one whose new end comes before the split
  with that reason, neither with a button. All events is left out for a
  series whose first start was never read.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 3]

  alias Tymeslot.CalendarGrid
  alias Tymeslot.CalendarGrid.SeriesEdit
  alias Tymeslot.Integrations.Calendar.Recurrence.Pattern
  alias Tymeslot.Integrations.Calendar.Recurrence.RRule
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

  @doc """
  The rule the pattern staged for `event` makes from the start the editor
  builds it from now (`Shared.series_anchor/3`), or `nil` for "Does not
  repeat". The fields are composed again rather than the rule kept, since
  the start may have moved since they were picked; fields that no longer
  make a rule (an end before the new start) keep the rule they made.
  """
  @spec draft_rule(map(), map(), map() | nil, String.t()) :: String.t() | nil
  def draft_rule(event, draft, edit, user_timezone) do
    {anchor, _known?} = Shared.series_anchor(event, edit, user_timezone)

    case compose(draft.params, event, anchor, user_timezone) do
      {:error, :until_before_start} -> draft.rule
      rule -> rule
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
    tz = socket.assigns.user_timezone
    {anchor, _known?} = Shared.series_anchor(event, edit, tz)

    case compose(params, event, anchor, tz) do
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

  defp compose(params, event, start, user_timezone) do
    Shared.compose_recurrence_rule(params, %{
      all_day: Map.get(event, :all_day, false),
      start_date: date_of(start),
      timezone: Shared.recurrence_timezone(event, user_timezone),
      rule: event.recurrence_rule
    })
  end

  defp save(socket, event, draft) do
    with :ok <- EditWorkflow.assert_event_writable(socket, event),
         :ok <- Shared.check_seat_lock(socket, event),
         :ok <- Shared.check_edit_rate_limit(socket) do
      if EditWorkflow.series_edit?(event),
        do: prompt_series(socket, event, draft),
        else: write_single(socket, event, draft)
    else
      {:error, reason} = error when reason in [:unauthorized, :read_only, :group_booking] ->
        Shared.flash_guard_error(socket, error)

      {:error, :rate_limited, _message} = error ->
        Shared.flash_guard_error(socket, error)
    end
  end

  # A single event given a rule becomes a series, which a CalDAV calendar
  # stores in the event's own zone so it keeps its local time across DST.
  defp write_single(socket, event, draft) do
    tz = socket.assigns.user_timezone
    timezone = Shared.recurrence_timezone(event, tz)
    start = Shared.recurrence_start(event, tz)
    rule = draft_rule(event, draft, socket.assigns[:recurrence_edit], tz)

    case CalendarGrid.repeat_refusal(Map.get(event, :provider), rule, date_of(start), timezone) do
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

  defp prompt_series(socket, event, draft) do
    rule =
      draft_rule(event, draft, socket.assigns[:recurrence_edit], socket.assigns.user_timezone)

    if is_nil(rule),
      do: refuse_rule_removal(socket),
      else: prompt_scopes(socket, event, draft)
  end

  # A series' repeat rule can be changed, never removed, from the grid: the
  # rule is what makes the events one series, and removing it from some of
  # them is not something any scope can write.
  defp refuse_rule_removal(socket) do
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

  defp prompt_scopes(socket, event, draft) do
    scopes = scope_rules(socket, event, draft)

    case Enum.filter(scopes, &offered?/1) do
      [] ->
        send(self(), {:flash, {:error, unavailable_message(scopes)}})
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

  @doc "Whether the prompt offers the scope `rule` describes (`scope_rules/3`)."
  @spec offered?(map()) :: boolean()
  def offered?(%{rule: rule, refusal: nil, ends_before: false}) when is_binary(rule), do: true
  def offered?(_scope_rule), do: false

  defp unavailable_message(scopes) do
    case Enum.find_value(scopes, & &1.refusal) do
      nil -> ends_before_message()
      reason -> refusal_message(reason)
    end
  end

  # What each scope writes, in the order the prompt lists them: from where
  # the series put the opened occurrence on, then the whole series, from its
  # first start when that is known.
  defp scope_rules(socket, event, draft) do
    tz = socket.assigns.user_timezone
    {series_start, known?} = Shared.series_anchor(event, socket.assigns[:recurrence_edit], tz)

    following = following_rule(event, draft, {series_start, known?}, tz)

    all =
      if known?,
        do:
          scope_rule(
            :all,
            compose(draft.params, event, series_start, tz),
            series_start,
            event,
            tz
          )

    Enum.reject([following, all], &is_nil/1)
  end

  defp following_rule(event, draft, series, tz) do
    with %{} = at <- CalendarGrid.occurrence_slot(event),
         slot = Shared.in_recurrence_zone(at, event, tz),
         rule when is_binary(rule) <- compose(draft.params, event, slot, tz),
         {:ok, rule} <- remaining_count(rule, event, series, slot) do
      scope_rule(:following, rule, slot, event, tz)
    else
      {:error, :until_before_start} -> ends_before(:following)
      :ends_before -> ends_before(:following)
      _unknown -> nil
    end
  end

  # The occurrences before the split stay in the series, so a new series
  # from the split repeats what is left of the `COUNT`.
  defp remaining_count(rule, event, {series_start, known?}, slot) do
    case RRule.parse(rule) do
      {:ok, %RRule{count: count} = parsed}
      when is_integer(count) and known? and is_binary(event.recurrence_rule) ->
        before = CalendarGrid.occurrences_before(event.recurrence_rule, series_start, slot)

        if count > before,
          do: {:ok, RRule.format(%{parsed | count: count - before})},
          else: :ends_before

      {:ok, %RRule{count: count}} when is_integer(count) ->
        :unknown

      _no_count ->
        {:ok, rule}
    end
  end

  defp scope_rule(scope, rule, start, event, tz) do
    timezone = Shared.recurrence_timezone(event, tz)

    %{
      scope: scope,
      rule: rule,
      summary: RecurrenceEditor.summary(rule, start),
      refusal:
        CalendarGrid.repeat_refusal(Map.get(event, :provider), rule, date_of(start), timezone),
      ends_before: false
    }
  end

  defp ends_before(scope),
    do: %{scope: scope, rule: nil, summary: nil, refusal: nil, ends_before: true}

  defp following_notes(event, scopes) do
    case Enum.find(scopes, &(&1.scope == :following and is_binary(&1.rule))) do
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

  @doc """
  What the organiser is told when the pattern's end comes before the
  occurrence a change of it and the following ones would start from.
  """
  @spec ends_before_message() :: String.t()
  def ends_before_message do
    dgettext(
      "dashboard_calendar_repeat",
      "Not available: the new end comes before this event, so there are no following events to change."
    )
  end

  defp date_of(%DateTime{} = at), do: DateTime.to_date(at)
  defp date_of(%Date{} = date), do: date
end
