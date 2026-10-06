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
  alias TymeslotWeb.Live.Scheduling.Handlers.BookingErrorMessage
  alias TymeslotWeb.Themes.Shared.GuestBooking
  alias TymeslotWeb.Themes.Shared.Journey.Ambient
  alias TymeslotWeb.Themes.Shared.Journey.Facts.Answers
  alias TymeslotWeb.Themes.Shared.Journey.Facts.Attendee
  alias TymeslotWeb.Themes.Shared.Journey.Facts.MeetingType
  alias TymeslotWeb.Themes.Shared.Journey.Facts.Slot
  alias TymeslotWeb.Themes.Shared.ReschedulePin
  alias TymeslotWeb.Themes.Shared.StateMachineHelpers, as: StateMachine

  @type reply :: {:noreply, Socket.t()}

  @doc """
  Handles an event a step component bubbled up.

  Returns `:unhandled` for an event the flow does not know, so the LiveView can
  offer it to the theme.
  """
  @spec handle_step_event(Socket.t(), atom(), atom(), term()) :: reply() | :unhandled
  def handle_step_event(socket, :overview, event, data) do
    if event in MeetingType.events(),
      do: MeetingType.handle(socket, event, data),
      else: overview_event(socket, event, data)
  end

  def handle_step_event(socket, :schedule, event, data) do
    cond do
      event in Slot.events() -> Slot.handle(socket, event, data)
      event in Ambient.events() -> Ambient.handle(socket, event, data)
      true -> schedule_event(socket, event, data)
    end
  end

  def handle_step_event(socket, :questions, event, data) do
    if event in Answers.events(),
      do: Answers.handle(socket, event, data),
      else: questions_event(socket, event, data)
  end

  def handle_step_event(socket, :booking, event, data) do
    if event in Attendee.events(),
      do: Attendee.handle(socket, event, data),
      else: booking_event(socket, event, data)
  end

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
  def handle_state_entry(socket, :schedule, params), do: Slot.enter(socket, params)

  def handle_state_entry(socket, :questions, _params), do: Answers.enter(socket, %{})

  def handle_state_entry(socket, :booking, params), do: Attendee.enter(socket, params)

  def handle_state_entry(socket, _state, _params), do: socket

  @doc """
  Handles a click on the step indicator: moves back to an earlier step (never
  forward), using `states_for/1` so the step numbers match the active state
  map (4 steps without custom fields, 5 with).
  """
  @spec navigate_to_step(Socket.t(), map()) :: reply()
  # `step` is guarded to a binary for the same reason `toggle_hour/2` in
  # `Journey.Facts.Slot` is: a crafted socket push can deliver a non-binary payload, which
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

  defp overview_event(socket, :next_step, _data),
    do: validated_transition(socket, :overview, :schedule)

  defp overview_event(_socket, _event, _data), do: :unhandled

  # Schedule

  defp schedule_event(socket, :back_step, _data) do
    if MeetingType.revisitable?(socket.assigns) do
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

  # Questions

  defp questions_event(socket, :next_step, _data) do
    case Answers.continue(socket) do
      {:done, socket} -> {:noreply, transition_to(socket, :booking, %{})}
      {:stay, socket} -> {:noreply, socket}
    end
  end

  defp questions_event(socket, :back_step, _data) do
    case Answers.back(socket) do
      {:leave, socket} -> {:noreply, transition_to(socket, :schedule, %{})}
      {:stay, socket} -> {:noreply, socket}
    end
  end

  defp questions_event(_socket, _event, _data), do: :unhandled

  # Booking

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
end
