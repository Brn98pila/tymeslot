defmodule TymeslotWeb.Themes.Shared.StateMachineHelpers do
  @moduledoc """
  Shared state machine logic for scheduling flows.
  """

  alias Tymeslot.Availability.Calculate
  alias Tymeslot.MeetingTypes
  alias TymeslotWeb.Themes.Shared.Journey.Facts.MeetingType
  alias TymeslotWeb.Themes.Shared.Journey.Facts.Slot

  # `awaiting_payment` is a transitional state used by embedded paid
  # bookings: Stripe Checkout opens in a new tab and the iframe waits for
  # the webhook to broadcast `:paid` (→ `:confirmation`) or `:expired`
  # (→ `:booking`). It shares step 4 with `:confirmation` so step
  # navigation does not let the attendee jump back during payment.
  @states_with_questions %{
    overview: %{step: 1, next: :schedule, prev: nil},
    schedule: %{step: 2, next: :questions, prev: :overview},
    questions: %{step: 3, next: :booking, prev: :schedule},
    booking: %{step: 4, next: :confirmation, prev: :questions},
    # `awaiting_payment` shares the final step with `:confirmation` (here step
    # 5) for the same reason it does in the default map: step navigation must
    # not let the attendee jump back while a paid booking is mid-payment.
    awaiting_payment: %{step: 5, prev: :booking},
    confirmation: %{step: 5, prev: :booking}
  }

  @default_states %{
    overview: %{step: 1, next: :schedule, prev: nil},
    schedule: %{step: 2, next: :booking, prev: :overview},
    booking: %{step: 3, next: :confirmation, prev: :schedule},
    awaiting_payment: %{step: 4, prev: :booking},
    confirmation: %{step: 4, prev: :booking}
  }

  @doc """
  Returns the default 4-step state configuration.
  """
  @spec default_states() :: map()
  def default_states, do: @default_states

  @doc """
  Returns the state map appropriate for a meeting type — 5 states when
  the meeting type has at least one custom field, the default 4 otherwise.
  """
  @spec states_for(map()) :: map()
  def states_for(%{custom_fields: defs}) when is_list(defs) and defs != [],
    do: @states_with_questions

  def states_for(_meeting_type), do: @default_states

  @doc """
  Checks if navigation to a target state is allowed based on the current state's step.
  Only allows navigation to previous or current steps.
  """
  @spec can_navigate_to_step?(Phoenix.LiveView.Socket.t(), atom(), map()) :: boolean()
  def can_navigate_to_step?(socket, target_state, states) do
    current_state = socket.assigns[:current_state]

    with %{step: current_step} <- states[current_state],
         %{step: target_step} <- states[target_state] do
      target_step <= current_step
    else
      _other -> false
    end
  end

  @spec determine_initial_state(atom()) :: :overview | :schedule | :booking | :confirmation
  def determine_initial_state(live_action) do
    case live_action do
      :overview -> :overview
      :schedule -> :schedule
      :booking -> :booking
      :confirmation -> :confirmation
      _other -> :overview
    end
  end

  @spec validate_state_transition(Phoenix.LiveView.Socket.t(), atom(), atom()) ::
          :ok | {:error, MeetingTypes.Duration.selection_error() | Calculate.selection_error()}
  def validate_state_transition(socket, current_state, next_state) do
    case {current_state, next_state} do
      {:overview, :schedule} ->
        validate_step_requirements(socket, :schedule)

      {:schedule, :questions} ->
        validate_step_requirements(socket, :questions)

      {:questions, :booking} ->
        :ok

      {:schedule, :booking} ->
        validate_step_requirements(socket, :booking)

      _other ->
        :ok
    end
  end

  @spec validate_step_requirements(Phoenix.LiveView.Socket.t(), atom()) ::
          :ok | {:error, MeetingTypes.Duration.selection_error() | Calculate.selection_error()}
  defp validate_step_requirements(socket, :schedule) do
    case MeetingType.continue(socket) do
      {:done, _socket} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Same precondition as :booking — booker must have selected a date and time.
  defp validate_step_requirements(socket, :questions),
    do: validate_step_requirements(socket, :booking)

  defp validate_step_requirements(socket, :booking) do
    case Slot.continue(socket) do
      {:done, _socket} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
