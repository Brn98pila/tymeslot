defmodule TymeslotWeb.Themes.Shared.SchedulingFlowTest do
  use Tymeslot.DataCase, async: true

  @moduletag :scheduling
  @moduletag :themes

  alias Phoenix.LiveView.Socket
  alias TymeslotWeb.Themes.Shared.CustomQuestions.Engine
  alias TymeslotWeb.Themes.Shared.SchedulingFlow

  defp socket(assigns), do: %Socket{assigns: Map.merge(%{__changed__: %{}, flash: %{}}, assigns)}

  defp question(id), do: %{"id" => id, "type" => "short_text", "label" => id, "required" => true}

  describe "schedule step" do
    test "picking a day clears the time and the hour grouping, and loads that day's slots" do
      socket =
        socket(%{selected_date: "2027-01-04", selected_time: "10:00", expanded_hour: :none})

      assert {:noreply, socket} =
               SchedulingFlow.handle_step_event(socket, :schedule, :select_date, "2027-01-05")

      assert %{selected_date: "2027-01-05", selected_time: nil, expanded_hour: nil} =
               socket.assigns

      assert socket.assigns.loading_slots
      assert_received {:load_slots, "2027-01-05"}
    end

    test "picking the chosen time again unchooses it" do
      socket = socket(%{selected_time: "10:00"})

      assert {:noreply, socket} =
               SchedulingFlow.handle_step_event(socket, :schedule, :select_time, "10:00")

      assert socket.assigns.selected_time == nil
    end

    test "a non-string hour is ignored rather than crashing the page" do
      socket = socket(%{expanded_hour: 11})

      assert {:noreply, ^socket} =
               SchedulingFlow.handle_step_event(socket, :schedule, :toggle_hour, 11)
    end

    test "back is refused to a booker who never saw the overview" do
      socket = socket(%{current_state: :schedule, entered_via_overview: false})

      assert {:noreply, socket} =
               SchedulingFlow.handle_step_event(socket, :schedule, :back_step, nil)

      assert socket.assigns.current_state == :schedule
    end

    test "an event the flow does not know is left to the theme" do
      assert SchedulingFlow.handle_step_event(socket(%{}), :schedule, :spin_globe, nil) ==
               :unhandled
    end

    test "month navigation is a shared schedule event, not a theme's" do
      socket = socket(%{current_year: 2027, current_month: 12})

      assert {:noreply, socket} =
               SchedulingFlow.handle_step_event(socket, :schedule, :next_month, nil)

      assert {socket.assigns.current_year, socket.assigns.current_month} == {2028, 1}
    end
  end

  describe "questions step" do
    test "next moves to the following question once the current one is answered" do
      engine =
        [question("company"), question("role")]
        |> Engine.init()
        |> Engine.answer("company", "Acme")

      assert {:noreply, socket} =
               SchedulingFlow.handle_step_event(
                 socket(%{current_state: :questions, engine: engine}),
                 :questions,
                 :next,
                 nil
               )

      assert socket.assigns.engine.current_index == 1
      assert socket.assigns.current_state == :questions
    end

    test "back from the first question returns to the schedule step" do
      engine = Engine.init([question("company")])

      assert {:noreply, socket} =
               SchedulingFlow.handle_step_event(
                 socket(%{current_state: :questions, engine: engine}),
                 :questions,
                 :back,
                 nil
               )

      assert socket.assigns.current_state == :schedule
    end
  end

  describe "navigate_to_step/2" do
    test "moves back to an earlier step" do
      socket = socket(%{current_state: :schedule, meeting_type: nil})

      assert {:noreply, socket} = SchedulingFlow.navigate_to_step(socket, %{"step" => "1"})
      assert socket.assigns.current_state == :overview
    end

    test "never skips ahead to a step the booker has not reached" do
      socket = socket(%{current_state: :overview, meeting_type: nil})

      assert {:noreply, socket} = SchedulingFlow.navigate_to_step(socket, %{"step" => "3"})
      assert socket.assigns.current_state == :overview
    end

    test "ignores a step that is not a string" do
      socket = socket(%{current_state: :schedule, meeting_type: nil})

      assert {:noreply, ^socket} = SchedulingFlow.navigate_to_step(socket, %{"step" => 1})
    end
  end
end
