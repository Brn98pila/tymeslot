defmodule TymeslotWeb.Themes.Shared.SchedulingLiveTest do
  use ExUnit.Case, async: true

  @moduletag :themes

  describe "use SchedulingLive" do
    test "refuses a theme that leaves out a step component" do
      assert_raise ArgumentError, ~r/missing.*:confirmation/, fn ->
        Code.compile_quoted(
          quote do
            defmodule TymeslotWeb.Themes.Shared.SchedulingLiveTest.MissingStepLive do
              use TymeslotWeb.Themes.Shared.SchedulingLive,
                wrapper: &TymeslotWeb.Themes.Quill.Scheduling.Wrapper.quill_wrapper/1,
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
