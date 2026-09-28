defmodule TymeslotWeb.Themes.Shared.SchedulingLiveTest do
  use ExUnit.Case, async: true

  alias Phoenix.LiveView.Socket
  alias TymeslotWeb.Themes.Quill.Scheduling.Wrapper

  @moduletag :themes

  defmodule OverridingLive do
    @moduledoc false

    alias TymeslotWeb.Themes.Quill.Scheduling.Components.{
      BookingComponent,
      ConfirmationComponent,
      CustomQuestionsComponent,
      OverviewComponent,
      ScheduleComponent
    }

    alias TymeslotWeb.Themes.Quill.Scheduling.Wrapper

    use TymeslotWeb.Themes.Shared.SchedulingLive,
      wrapper: &Wrapper.quill_wrapper/1,
      steps: %{
        overview: OverviewComponent,
        schedule: ScheduleComponent,
        questions: CustomQuestionsComponent,
        booking: BookingComponent,
        confirmation: ConfirmationComponent
      }

    # Overriding the hook replaces every clause of the default, which is how
    # a theme used to lose the step indicator without any warning.
    defp handle_theme_event("theme_ping", _params, socket),
      do: {:noreply, assign(socket, :theme_pinged, true)}

    defp handle_theme_event(_event, _params, socket), do: {:noreply, socket}
  end

  defp socket(assigns), do: %Socket{assigns: Map.merge(%{__changed__: %{}, flash: %{}}, assigns)}

  describe "a theme with its own events" do
    test "still lets the booker go back through the step indicator" do
      socket = socket(%{current_state: :schedule, meeting_type: nil})

      assert {:noreply, socket} =
               OverridingLive.handle_event("navigate_to_step", %{"step" => "1"}, socket)

      assert socket.assigns.current_state == :overview
    end

    test "still receives its own events" do
      assert {:noreply, socket} =
               OverridingLive.handle_event("theme_ping", %{}, socket(%{current_state: :overview}))

      assert socket.assigns.theme_pinged
    end
  end

  describe "use SchedulingLive" do
    test "refuses a theme that leaves out a step component" do
      assert_raise ArgumentError, ~r/missing.*:confirmation/, fn ->
        Code.compile_quoted(
          quote do
            defmodule TymeslotWeb.Themes.Shared.SchedulingLiveTest.MissingStepLive do
              use TymeslotWeb.Themes.Shared.SchedulingLive,
                wrapper: &Wrapper.quill_wrapper/1,
                steps: %{
                  overview: TymeslotWeb.Themes.Quill.Scheduling.Components.OverviewComponent,
                  schedule: TymeslotWeb.Themes.Quill.Scheduling.Components.ScheduleComponent,
                  questions:
                    TymeslotWeb.Themes.Quill.Scheduling.Components.CustomQuestionsComponent,
                  booking: TymeslotWeb.Themes.Quill.Scheduling.Components.BookingComponent
                }
            end
          end
        )
      end
    end

    test "refuses a step it does not know" do
      assert_raise ArgumentError, ~r/does not know.*:awaiting_payment/, fn ->
        Code.compile_quoted(
          quote do
            defmodule TymeslotWeb.Themes.Shared.SchedulingLiveTest.UnknownStepLive do
              use TymeslotWeb.Themes.Shared.SchedulingLive,
                wrapper: &Wrapper.quill_wrapper/1,
                steps: %{
                  overview: TymeslotWeb.Themes.Quill.Scheduling.Components.OverviewComponent,
                  schedule: TymeslotWeb.Themes.Quill.Scheduling.Components.ScheduleComponent,
                  questions:
                    TymeslotWeb.Themes.Quill.Scheduling.Components.CustomQuestionsComponent,
                  booking: TymeslotWeb.Themes.Quill.Scheduling.Components.BookingComponent,
                  confirmation:
                    TymeslotWeb.Themes.Quill.Scheduling.Components.ConfirmationComponent,
                  awaiting_payment:
                    TymeslotWeb.Themes.Quill.Scheduling.Components.ConfirmationComponent
                }
            end
          end
        )
      end
    end

    test "refuses a step that is not a LiveComponent" do
      assert_raise CompileError,
                   ~r/step :confirmation.*TymeslotWeb\.Themes\.Quill\.Scheduling\.Live\b/,
                   fn ->
                     Code.compile_quoted(
                       quote do
                         defmodule TymeslotWeb.Themes.Shared.SchedulingLiveTest.LiveViewStepLive do
                           use TymeslotWeb.Themes.Shared.SchedulingLive,
                             wrapper: &Wrapper.quill_wrapper/1,
                             steps: %{
                               overview:
                                 TymeslotWeb.Themes.Quill.Scheduling.Components.OverviewComponent,
                               schedule:
                                 TymeslotWeb.Themes.Quill.Scheduling.Components.ScheduleComponent,
                               questions:
                                 TymeslotWeb.Themes.Quill.Scheduling.Components.CustomQuestionsComponent,
                               booking:
                                 TymeslotWeb.Themes.Quill.Scheduling.Components.BookingComponent,
                               confirmation: TymeslotWeb.Themes.Quill.Scheduling.Live
                             }
                         end
                       end
                     )
                   end
    end

    test "refuses a step component that does not exist" do
      assert_raise CompileError, ~r/step :booking.*NoSuchComponent/, fn ->
        Code.compile_quoted(
          quote do
            defmodule TymeslotWeb.Themes.Shared.SchedulingLiveTest.MissingModuleLive do
              use TymeslotWeb.Themes.Shared.SchedulingLive,
                wrapper: &Wrapper.quill_wrapper/1,
                steps: %{
                  overview: TymeslotWeb.Themes.Quill.Scheduling.Components.OverviewComponent,
                  schedule: TymeslotWeb.Themes.Quill.Scheduling.Components.ScheduleComponent,
                  questions:
                    TymeslotWeb.Themes.Quill.Scheduling.Components.CustomQuestionsComponent,
                  booking: TymeslotWeb.Themes.Quill.Scheduling.Components.NoSuchComponent,
                  confirmation:
                    TymeslotWeb.Themes.Quill.Scheduling.Components.ConfirmationComponent
                }
            end
          end
        )
      end
    end

    test "refuses the retired theme_id option" do
      assert_raise ArgumentError, ~r/theme_id/, fn ->
        Code.compile_quoted(
          quote do
            defmodule TymeslotWeb.Themes.Shared.SchedulingLiveTest.ThemeIdLive do
              use TymeslotWeb.Themes.Shared.SchedulingLive, theme_id: "1"
            end
          end
        )
      end
    end
  end
end
