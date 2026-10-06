defmodule TymeslotWeb.Themes.Shared.Journey.RuntimeTest do
  use Tymeslot.DataCase, async: true

  @moduletag :scheduling
  @moduletag :themes

  alias Phoenix.LiveView.Socket

  alias TymeslotWeb.Test.FixtureTheme.Scheduling.{
    BookingStep,
    ConfirmationStep,
    OverviewStep,
    QuestionsStep,
    ScheduleStep
  }

  alias TymeslotWeb.Themes.Shared.CustomQuestions.Engine
  alias TymeslotWeb.Themes.Shared.Journey
  alias TymeslotWeb.Themes.Shared.Journey.Runtime

  defp classic do
    Journey.new(
      Journey.classic(%{
        overview: OverviewStep,
        schedule: ScheduleStep,
        questions: QuestionsStep,
        booking: BookingStep,
        confirmation: ConfirmationStep
      })
    )
  end

  defp socket(assigns),
    do: %Socket{assigns: Map.merge(%{__changed__: %{}, flash: %{}, journey: classic()}, assigns)}

  defp question(id), do: %{"id" => id, "type" => "short_text", "label" => id, "required" => true}

  describe "transition_to/3" do
    test "showing an outcome only names it" do
      socket = socket(%{current_state: :booking, meeting_uid: "abc"})
      shown = Runtime.transition_to(socket, :confirmation, %{})

      assert shown.assigns.current_state == :confirmation

      assert Map.drop(shown.assigns, [:current_state, :__changed__]) ==
               Map.drop(socket.assigns, [:current_state, :__changed__])
    end

    test "showing a moment runs what its facts set up" do
      socket =
        socket(%{current_state: :schedule, meeting_type: %{custom_fields: [question("company")]}})

      socket = Runtime.transition_to(socket, :questions, %{})

      assert socket.assigns.current_state == :questions
      assert %Engine{} = socket.assigns.engine
      assert Engine.total(socket.assigns.engine) == 1
    end
  end
end
