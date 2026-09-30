defmodule TymeslotWeb.Themes.Shared.SchedulingFlow do
  @moduledoc """
  The booking flow every scheduling theme runs: what each step's events do,
  how the flow moves between steps, and what entering a step sets up.

  A theme's LiveView reaches this through `SchedulingLive`, which routes each
  `{:step_event, step, event, data}` message from a step component to
  `handle_step_event/4`. Nothing here depends on which theme is rendering.
  """

  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Phoenix.LiveView.Socket
  alias TymeslotWeb.Components.MeetingUtils

  alias TymeslotWeb.Live.Scheduling.{
    AvailabilityHelpers,
    CalendarHelpers,
    NextAvailable,
    OrganizerHelpers,
    WeekSlots
  }

  alias TymeslotWeb.Live.Scheduling.Handlers.BookingErrorMessage
  alias TymeslotWeb.Live.Scheduling.Handlers.SlotFetchingHandlerComponent
  alias TymeslotWeb.Live.Scheduling.Handlers.TimezoneHandlerComponent
  alias TymeslotWeb.Themes.Shared.BookingFlow
  alias TymeslotWeb.Themes.Shared.BookingLocation
  alias TymeslotWeb.Themes.Shared.CustomQuestions.Engine, as: QEngine
  alias TymeslotWeb.Themes.Shared.EventHandlers
  alias TymeslotWeb.Themes.Shared.GuestBooking
  alias TymeslotWeb.Themes.Shared.LiveHelpers.StepEntry
  alias TymeslotWeb.Themes.Shared.ReschedulePin
  alias TymeslotWeb.Themes.Shared.SlotGrouping
  alias TymeslotWeb.Themes.Shared.StateMachineHelpers, as: StateMachine

  @type reply :: {:noreply, Socket.t()}

  @doc """
  Handles an event a step component bubbled up.

  Returns `:unhandled` for an event the flow does not know, so the LiveView can
  offer it to the theme.
  """
  @spec handle_step_event(Socket.t(), atom(), atom(), term()) :: reply() | :unhandled
  def handle_step_event(socket, :overview, event, data), do: overview_event(socket, event, data)
  def handle_step_event(socket, :schedule, event, data), do: schedule_event(socket, event, data)
  def handle_step_event(socket, :questions, event, data), do: questions_event(socket, event, data)
  def handle_step_event(socket, :booking, event, data), do: booking_event(socket, event, data)

  def handle_step_event(socket, :confirmation, event, data),
    do: confirmation_event(socket, event, data)

  def handle_step_event(_socket, _step, _event, _data), do: :unhandled

  @doc """
  Moves the flow to `new_state` and runs what entering it sets up.
  """
  @spec transition_to(Socket.t(), atom(), map()) :: Socket.t()
  def transition_to(socket, new_state, params) do
    socket
    |> assign(:current_state, new_state)
    |> handle_state_entry(new_state, params)
  end

  @doc """
  What entering `state` sets up; `params` are the URL parameters, or `%{}` for
  a transition made inside the page.
  """
  @spec handle_state_entry(Socket.t(), atom(), map()) :: Socket.t()
  # Every arrival at the step fetches a week view's week again: the duration
  # can have changed on the overview, and a booking that lost its slot comes
  # back here. A no-op for a page that shows no week.
  def handle_state_entry(socket, :schedule, params) do
    socket
    |> StepEntry.handle_schedule_entry(params)
    |> refresh_stale_slot_snapshot()
    |> WeekSlots.refetch()
  end

  def handle_state_entry(socket, :questions, _params),
    do: StepEntry.handle_questions_entry(socket)

  def handle_state_entry(socket, :booking, params),
    do: StepEntry.handle_booking_entry(socket, params)

  def handle_state_entry(socket, _state, _params), do: socket

  @doc """
  Handles a click on the step indicator: moves back to an earlier step (never
  forward), using `states_for/1` so the step numbers match the active state
  map (4 steps without custom fields, 5 with).
  """
  @spec navigate_to_step(Socket.t(), map()) :: reply()
  # `step` is guarded to a binary for the same reason `toggle_hour/2` below
  # is: a crafted socket push can deliver a non-binary payload, which
  # `Integer.parse/1` has no clause for.
  def navigate_to_step(socket, %{"step" => step}) when is_binary(step) do
    states = StateMachine.states_for(socket.assigns[:meeting_type] || %{})

    target_step =
      case Integer.parse(step) do
        {n, _rest} -> n
        :error -> nil
      end

    target_state =
      case Enum.find(states, fn {_state, %{step: n}} -> n == target_step end) do
        {state, _meta} -> state
        nil -> socket.assigns[:current_state]
      end

    if target_state != socket.assigns[:current_state] and
         StateMachine.can_navigate_to_step?(socket, target_state, states) do
      {:noreply, transition_to(socket, target_state, %{})}
    else
      {:noreply, socket}
    end
  end

  def navigate_to_step(socket, _params), do: {:noreply, socket}

  # Overview

  # A pinned reschedule has no choice of type to make, so the payload is
  # ignored rather than trusted; `ReschedulePin` says why that matters even
  # though no second card is rendered to click.
  defp overview_event(socket, :select_duration, data) do
    duration = ReschedulePin.selected_duration(socket, data)

    socket =
      socket
      |> assign(selected_duration: duration, duration: duration)
      |> StepEntry.maybe_assign_meeting_type(duration)
      # Trigger availability refresh when duration changes
      |> AvailabilityHelpers.fetch_month_availability_async()

    {:noreply, socket}
  end

  defp overview_event(socket, :next_step, _data),
    do: validated_transition(socket, :overview, :schedule)

  defp overview_event(_socket, _event, _data), do: :unhandled

  # Schedule

  defp schedule_event(socket, :select_date, date), do: select_date(socket, date)

  defp schedule_event(socket, :select_time, time) do
    new_time = if socket.assigns[:selected_time] == time, do: nil, else: time
    {:noreply, assign(socket, :selected_time, new_time)}
  end

  defp schedule_event(socket, :toggle_hour, hour), do: toggle_hour(socket, hour)
  defp schedule_event(socket, :change_timezone, data), do: change_timezone(socket, data)

  defp schedule_event(socket, :search_timezone, data),
    do: EventHandlers.handle_timezone_search(socket, data)

  defp schedule_event(socket, :toggle_timezone_dropdown, _data),
    do:
      {:noreply,
       assign(socket, :timezone_dropdown_open, !socket.assigns[:timezone_dropdown_open])}

  defp schedule_event(socket, :close_timezone_dropdown, _data) do
    Process.send_after(self(), :close_dropdown, 150)
    {:noreply, socket}
  end

  defp schedule_event(socket, :prev_week, _data),
    do: {:noreply, socket |> CalendarHelpers.handle_week_navigation(:prev) |> WeekSlots.refetch()}

  defp schedule_event(socket, :next_week, _data),
    do: {:noreply, socket |> CalendarHelpers.handle_week_navigation(:next) |> WeekSlots.refetch()}

  # A week view asking for its week; see `WeekSlots.load/1`.
  defp schedule_event(socket, :load_week, _data), do: {:noreply, WeekSlots.load(socket)}

  defp schedule_event(socket, :prev_month, _data),
    do: {:noreply, CalendarHelpers.handle_month_navigation(socket, :prev)}

  defp schedule_event(socket, :next_month, _data),
    do: {:noreply, CalendarHelpers.handle_month_navigation(socket, :next)}

  # Only allow returning to the overview when the booker actually entered via
  # it. A direct/private-link entry sets `entered_via_overview: false` and must
  # never expose the organiser's other meeting types — enforce this
  # server-side so a client cannot bypass the template-level `:if` guard by
  # pushing the event directly.
  defp schedule_event(socket, :back_step, _data) do
    if socket.assigns[:entered_via_overview] do
      validated_transition(socket, :schedule, :overview)
    else
      {:noreply, socket}
    end
  end

  # Route to :questions when the meeting type has custom fields, else :booking.
  defp schedule_event(socket, :next_step, _data) do
    states = StateMachine.states_for(socket.assigns[:meeting_type] || %{})
    next = get_in(states, [:schedule, :next]) || :booking
    validated_transition(socket, :schedule, next)
  end

  defp schedule_event(_socket, _event, _data), do: :unhandled

  # Defensive on the nil date: neither theme's day button deselects any
  # more, so nothing reaches here with nil today. The guard stays because
  # sending {:load_slots, nil} would fetch slots for no day at all.
  #
  # Resets `:expanded_hour` here, at the point the booker actively picks
  # a date, rather than in the fetch that follows: the fetch also runs
  # for refetches the booker did not cause a date change with (a
  # timezone change, a lost-slot retry), which must not spring a
  # deliberately collapsed `:none` back open.
  defp select_date(socket, date) do
    socket =
      assign(socket,
        selected_date: date,
        selected_time: nil,
        expanded_hour: nil,
        loading_slots: date != nil,
        calendar_error: nil
      )

    if date, do: send(self(), {:load_slots, date})
    {:noreply, socket}
  end

  # `expanded_hour` holds three states, not two: nil means "not chosen, so
  # open the earliest hour", an integer means that hour, and :none means the
  # booker closed it and it must stay closed until they choose again.
  #
  # `hour` is guarded to a binary because event payloads for non-"form"
  # events reach `handle_event/3` verbatim from client JSON with no type
  # coercion — a crafted socket push can deliver a list or map here, which
  # `Integer.parse/1` has no clause for. A non-binary payload is ignored,
  # leaving state untouched, the same way an unparsable string already is.
  defp toggle_hour(socket, hour) when is_binary(hour) do
    grouping =
      SlotGrouping.group(
        MeetingUtils.normalize_slot_list(socket.assigns[:available_slots] || []),
        socket.assigns[:slot_interval_minutes],
        socket.assigns[:duration_minutes]
      )

    current = SlotGrouping.effective_expanded_hour(socket.assigns[:expanded_hour], grouping)

    next =
      case Integer.parse(hour) do
        {^current, ""} -> :none
        {requested, ""} -> requested
        _unparsable -> socket.assigns[:expanded_hour]
      end

    {:noreply, assign(socket, :expanded_hour, next)}
  end

  defp toggle_hour(socket, _hour), do: {:noreply, socket}

  # The picker's choice goes through `TimezoneHandlerComponent`, which switches
  # the zone. A zone that actually changed then decides which day stays
  # selected (`NextAvailable.follow_timezone_change/1`), reloads that day's
  # slots in the new zone, if one is left, and refetches the month, whose days
  # are worked out in the visitor's timezone. A week view's week is fetched
  # again too, for the times in the new zone. The slots are reloaded only after
  # the day is settled, so none are fetched for a day about to be dropped. An
  # invalid choice leaves `:user_timezone`, and so everything else, as it was.
  defp change_timezone(socket, data) do
    previous = socket.assigns[:user_timezone]

    case TimezoneHandlerComponent.handle_timezone_change(socket, data) do
      {:ok, %Socket{assigns: %{user_timezone: ^previous}} = unchanged} ->
        {:noreply, unchanged}

      {:ok, updated_socket} ->
        socket =
          updated_socket
          |> NextAvailable.follow_timezone_change()
          |> AvailabilityHelpers.fetch_month_availability_async()
          |> WeekSlots.refetch()

        {:ok, socket} = SlotFetchingHandlerComponent.maybe_reload_slots(socket)
        {:noreply, socket}
    end
  end

  # Questions

  defp questions_event(socket, :answer, {id, value}) do
    engine = QEngine.answer(socket.assigns.engine, id, value)
    {:noreply, assign(socket, :engine, engine)}
  end

  defp questions_event(socket, :next, _data), do: questions_next(socket)
  defp questions_event(socket, :back, _data), do: questions_back(socket)
  defp questions_event(_socket, _event, _data), do: :unhandled

  # Advance within the questions wizard, or proceed to :booking when all
  # questions have been answered and validated.
  #
  # Transitions to :booking only when the booker is already on the last
  # question and presses Next — this ensures a single optional question is
  # always shown before the wizard exits, even when it validates as empty.
  defp questions_next(socket) do
    engine = socket.assigns.engine

    if QEngine.skipped?(engine) do
      {:noreply, transition_to(socket, :booking, %{})}
    else
      last_index = QEngine.total(engine) - 1

      cond do
        engine.current_index < last_index ->
          case QEngine.next(engine) do
            {:ok, engine} -> {:noreply, assign(socket, :engine, engine)}
            {:error, engine} -> {:noreply, assign(socket, :engine, engine)}
          end

        engine.current_index == last_index ->
          case QEngine.validate_all(engine) do
            {:ok, _answers} ->
              socket = assign(socket, :engine, QEngine.mark_reviewed(engine))
              {:noreply, transition_to(socket, :booking, %{})}

            {:error, _errors} ->
              case QEngine.next(engine) do
                {:ok, engine} -> {:noreply, assign(socket, :engine, engine)}
                {:error, engine} -> {:noreply, assign(socket, :engine, engine)}
              end
          end

        true ->
          {:noreply, socket}
      end
    end
  end

  # Move backwards within the wizard, or return to :schedule from the first question.
  defp questions_back(socket) do
    engine = socket.assigns.engine

    if engine.current_index == 0 do
      {:noreply, transition_to(socket, :schedule, %{})}
    else
      {:noreply, assign(socket, :engine, QEngine.prev(engine))}
    end
  end

  # Booking

  defp booking_event(socket, :validate, data),
    do: BookingFlow.handle_form_validation(socket, data)

  defp booking_event(socket, :field_blur, field),
    do: {:noreply, OrganizerHelpers.mark_field_touched(socket, field)}

  defp booking_event(socket, event, data)
       when event in [:select_location, :select_video_provider, :location_phone],
       do: {:noreply, BookingLocation.apply_event(socket, event, data)}

  defp booking_event(socket, :toggle_guests, _data), do: {:noreply, GuestBooking.open(socket)}
  defp booking_event(socket, :close_guests, _data), do: {:noreply, GuestBooking.close(socket)}

  defp booking_event(socket, :guest_input, data),
    do: {:noreply, GuestBooking.set_input(socket, data)}

  defp booking_event(socket, :add_guest, data), do: {:noreply, GuestBooking.add(socket, data)}

  defp booking_event(socket, :remove_guest, data),
    do: {:noreply, GuestBooking.remove(socket, data)}

  defp booking_event(socket, :submit, data),
    do: BookingFlow.submit_booking(socket, data, &transition_to/3)

  # Route back to :questions when the meeting type has custom fields, else :schedule.
  defp booking_event(socket, :back_step, _data) do
    states = StateMachine.states_for(socket.assigns[:meeting_type] || %{})
    prev = get_in(states, [:booking, :prev]) || :schedule
    validated_transition(socket, :booking, prev)
  end

  defp booking_event(_socket, _event, _data), do: :unhandled

  # Confirmation

  # The flow restarts here without navigating, so the reschedule context has
  # to be dropped explicitly or the next submit moves the meeting that was
  # just moved (see `ReschedulePin.abandon/1`). The day and time belong to
  # the booking just made: kept, the schedule step would reopen the calendar
  # on them, with a time that is no longer free.
  defp confirmation_event(socket, :schedule_another, _data) do
    socket =
      socket
      |> GuestBooking.assign_defaults()
      |> ReschedulePin.abandon()
      |> assign(selected_date: nil, selected_time: nil)

    {:noreply, transition_to(socket, :overview, %{})}
  end

  defp confirmation_event(_socket, _event, _data), do: :unhandled

  # Transitions

  # `reason` is a semantic atom from the step validators; rendering it to copy
  # is this layer's job, and the booking page is multi-locale.
  defp validated_transition(socket, current_state, next_state) do
    case StateMachine.validate_state_transition(socket, current_state, next_state) do
      :ok ->
        {:noreply, transition_to(socket, next_state, %{})}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, BookingErrorMessage.message(reason))}
    end
  end

  # `:available_slots`, `:duration_minutes`, `:slot_interval_minutes` and
  # `:expanded_hour` are snapshotted by `SlotFetchingHandlerComponent` at
  # fetch time and do not track a meeting-type/duration change made while
  # away from this step (e.g. back to :overview, pick a different
  # duration, forward again). Only compare against a snapshot that
  # actually exists (`:duration_minutes` non-nil) — the very first entry
  # into :schedule has no snapshot yet and nothing stale to refresh.
  defp refresh_stale_slot_snapshot(socket) do
    case socket.assigns[:duration_minutes] do
      nil ->
        socket

      snapshot_duration ->
        current_duration = AvailabilityHelpers.duration_minutes(socket)
        current_interval = AvailabilityHelpers.slot_interval_minutes(socket)

        if snapshot_duration == current_duration and
             socket.assigns[:slot_interval_minutes] == current_interval do
          socket
        else
          socket
          |> assign(
            available_slots: [],
            selected_time: nil,
            expanded_hour: nil,
            duration_minutes: nil,
            slot_interval_minutes: nil
          )
          |> then(fn socket ->
            {:ok, socket} = SlotFetchingHandlerComponent.maybe_reload_slots(socket)
            socket
          end)
        end
    end
  end
end
