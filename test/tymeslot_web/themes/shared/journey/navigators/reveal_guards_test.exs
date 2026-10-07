defmodule TymeslotWeb.Themes.Shared.Journey.Navigators.RevealGuardsTest do
  @moduledoc """
  The guards a navigator that reveals several moments (`Navigators.Reveal`)
  must keep, through `Journey.Runtime` as `SchedulingLive` drives it: events
  are taken only from a visible moment, nothing moves while a checkout is
  open, and "Schedule another meeting" starts again on the journey's entry.
  """
  use Tymeslot.DataCase, async: true

  @moduletag :scheduling
  @moduletag :themes
  @moduletag :integration

  alias Phoenix.LiveView.Socket
  alias TymeslotWeb.Themes.Shared.Journey
  alias TymeslotWeb.Themes.Shared.Journey.Moment
  alias TymeslotWeb.Themes.Shared.Journey.Navigators.Continuous
  alias TymeslotWeb.Themes.Shared.Journey.Runtime

  @intro %{name: "Intro call", slug: "intro-call", duration_minutes: 30}

  @navigators [Continuous]

  defp journey(navigator) do
    %Journey{
      navigator: navigator,
      outcomes: %{},
      moments: [
        %Moment{key: :intro, collects: [], component: nil, defaults: []},
        %Moment{key: :offer, collects: [:meeting_type], component: nil, defaults: []},
        %Moment{key: :when, collects: [:slot], component: nil, defaults: []},
        %Moment{key: :you, collects: [:attendee], component: nil, defaults: []}
      ]
    }
  end

  # A booker on the times: the meeting type chosen, no slot yet, every moment
  # reached already open (so settling enters nothing again).
  defp at_times(navigator, assigns \\ %{}) do
    %Socket{
      assigns:
        Map.merge(
          %{
            __changed__: %{},
            flash: %{},
            journey: journey(navigator),
            current_state: :when,
            journey_opened: MapSet.new([:intro, :offer, :when]),
            meeting_type: @intro,
            selected_duration: "intro-call",
            selected_date: nil,
            selected_time: nil,
            timezone_dropdown_open: false,
            user_timezone: "Europe/London"
          },
          assigns
        )
    }
  end

  for navigator <- @navigators do
    describe "#{inspect(navigator)}" do
      setup do: %{navigator: unquote(navigator)}

      test "takes the timezone picker's events from a visible moment only", %{navigator: nav} do
        socket = at_times(nav)

        for moment <- [:intro, :offer, :when] do
          assert {:noreply, toggled} =
                   Runtime.handle_step_event(socket, moment, :toggle_timezone_dropdown, nil)

          assert toggled.assigns.timezone_dropdown_open
        end

        assert Runtime.handle_step_event(socket, :you, :toggle_timezone_dropdown, nil) ==
                 :unhandled

        assert Runtime.handle_step_event(socket, nil, :toggle_timezone_dropdown, nil) ==
                 :unhandled
      end

      test "takes no ambient or fact event on an outcome", %{navigator: nav} do
        for outcome <- [:confirmation, :awaiting_payment] do
          socket = at_times(nav, %{current_state: outcome})

          assert Runtime.handle_step_event(socket, outcome, :change_timezone, "Asia/Tokyo") ==
                   :unhandled

          assert Runtime.handle_step_event(socket, :when, :change_timezone, "Asia/Tokyo") ==
                   :unhandled

          assert Runtime.handle_step_event(socket, :when, :select_date, "2027-01-05") ==
                   :unhandled

          assert Runtime.handle_step_event(socket, :offer, :select_duration, "intro-call") ==
                   :unhandled
        end
      end

      test "takes no fact event from a moment not reached yet", %{navigator: nav} do
        assert Runtime.handle_step_event(at_times(nav), :you, :validate, %{}) == :unhandled
      end

      test "takes next and back only from the current moment", %{navigator: nav} do
        socket = at_times(nav)

        assert Runtime.handle_step_event(socket, :offer, :next_step, nil) == :unhandled
        assert Runtime.handle_step_event(socket, :intro, :back_step, nil) == :unhandled
      end

      test "moves nothing while a checkout is open", %{navigator: nav} do
        socket =
          at_times(nav, %{
            current_state: :awaiting_payment,
            selected_date: "2027-01-05",
            selected_time: "10:00",
            journey_opened: MapSet.new([:intro, :offer, :when, :you])
          })

        journey = socket.assigns.journey

        assert Runtime.handle_step_event(socket, :awaiting_payment, :next_step, nil) ==
                 :unhandled

        assert Runtime.handle_step_event(socket, :you, :back_step, nil) == :unhandled
        assert nav.continue(journey, socket) == {:noreply, socket}
        assert nav.back(journey, socket) == {:noreply, socket}
        assert Runtime.settle(socket) == socket

        for step <- ["intro", "offer", "when", "you", "1", "confirmation"] do
          assert Runtime.navigate_to_step(socket, %{"step" => step}) == {:noreply, socket}
        end
      end

      test "starts again on the moment still to complete, the slot forgotten", %{navigator: nav} do
        for via_overview <- [true, false] do
          socket =
            at_times(nav, %{
              current_state: :confirmation,
              client_ip: "127.0.0.1",
              entered_via_overview: via_overview,
              selected_date: "2027-01-05",
              selected_time: "10:00",
              meeting_uid: "booked",
              journey_opened: MapSet.new()
            })

          assert {:noreply, restarted} =
                   Runtime.handle_step_event(socket, :confirmation, :schedule_another, nil)

          assert %{
                   current_state: :when,
                   meeting_type: @intro,
                   selected_date: nil,
                   selected_time: nil
                 } = restarted.assigns

          assert restarted.assigns.journey_opened == MapSet.new([:intro, :offer, :when])
        end
      end
    end
  end
end
