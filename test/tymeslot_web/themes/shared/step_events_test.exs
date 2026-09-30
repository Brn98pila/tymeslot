defmodule TymeslotWeb.Themes.Shared.StepEventsTest do
  use ExUnit.Case, async: true

  @moduletag :scheduling
  @moduletag :themes

  alias Phoenix.LiveView.Socket
  alias TymeslotWeb.Themes.Shared.StepEvents

  defp socket(assigns), do: %Socket{assigns: Map.merge(%{__changed__: %{}}, assigns)}

  # {step, event, params, message the LiveView receives}
  @relays [
    {:overview, "select_duration", %{"duration" => "30-minutes"},
     {:select_duration, "30-minutes"}},
    {:overview, "next_step", %{}, {:next_step, nil}},
    {:schedule, "select_date", %{"date" => "2027-01-05"}, {:select_date, "2027-01-05"}},
    {:schedule, "select_time", %{"time" => "10:00"}, {:select_time, "10:00"}},
    {:schedule, "toggle_hour", %{"hour" => "10"}, {:toggle_hour, "10"}},
    {:schedule, "change_timezone", %{"timezone" => "Asia/Tokyo"},
     {:change_timezone, "Asia/Tokyo"}},
    {:schedule, "search_timezone", %{"search" => "tok"},
     {:search_timezone, %{"search" => "tok"}}},
    {:schedule, "toggle_timezone_dropdown", %{}, {:toggle_timezone_dropdown, nil}},
    {:schedule, "close_timezone_dropdown", %{}, {:close_timezone_dropdown, nil}},
    {:schedule, "prev_month", %{}, {:prev_month, nil}},
    {:schedule, "next_month", %{}, {:next_month, nil}},
    {:schedule, "prev_week", %{}, {:prev_week, nil}},
    {:schedule, "next_week", %{}, {:next_week, nil}},
    {:schedule, "load_week", %{}, {:load_week, nil}},
    {:schedule, "back_step", %{}, {:back_step, nil}},
    {:schedule, "next_step", %{}, {:next_step, nil}},
    {:booking, "validate", %{"booking" => %{"name" => "A"}}, {:validate, %{"name" => "A"}}},
    {:booking, "field_blur", %{"field" => "email"}, {:field_blur, "email"}},
    {:booking, "back_step", %{}, {:back_step, nil}},
    {:booking, "select_location", %{"id" => "loc-1"}, {:select_location, "loc-1"}},
    {:booking, "select_video_provider", %{"id" => "zoom"}, {:select_video_provider, "zoom"}},
    {:booking, "location_phone_change", %{"location_phone" => "+372"}, {:location_phone, "+372"}},
    {:booking, "location_phone_change", %{}, {:location_phone, ""}},
    {:booking, "toggle_guests", %{}, {:toggle_guests, nil}},
    {:booking, "close_guests", %{}, {:close_guests, nil}},
    {:booking, "guest_input_change", %{"guest_email" => "a@b.c"}, {:guest_input, "a@b.c"}},
    {:booking, "add_guest", %{"guest_email" => "a@b.c"}, {:add_guest, "a@b.c"}},
    {:booking, "remove_guest", %{"email" => "a@b.c"}, {:remove_guest, "a@b.c"}},
    {:confirmation, "schedule_another", %{}, {:schedule_another, nil}}
  ]

  test "relays every canonical event to the LiveView under the step on screen" do
    for {step, event, params, {name, data}} <- @relays do
      assert {:noreply, _socket} =
               StepEvents.handle_event(event, params, socket(%{current_state: step}))

      assert_received {:step_event, ^step, ^name, ^data},
                      "#{event} on #{step} did not relay as #{inspect({name, data})}"
    end
  end

  test "submitting relays the form and shows the submitting state at once" do
    socket = socket(%{current_state: :booking})

    assert {:noreply, socket} =
             StepEvents.handle_event("submit", %{"booking" => %{"name" => "A"}}, socket)

    assert socket.assigns.submitting
    assert_received {:step_event, :booking, :submit, %{"name" => "A"}}
  end

  test "ignores an event outside the canonical set rather than crashing" do
    socket = socket(%{current_state: :schedule})

    assert {:noreply, ^socket} = StepEvents.handle_event("next_slide", %{}, socket)
    refute_received {:step_event, _step, _event, _data}
  end

  test "relays a theme's own event untouched, under the step on screen" do
    for step <- [:overview, :schedule, :booking, :confirmation] do
      assert {:noreply, _socket} =
               StepEvents.handle_event(
                 "theme:flip",
                 %{"card" => "3"},
                 socket(%{current_state: step})
               )

      assert_received {:step_event, ^step, "theme:flip", %{"card" => "3"}},
                      "theme:flip on #{step} was not relayed"
    end
  end

  test "update/2 takes the LiveView's assigns, minus the ones a component cannot hold" do
    assert {:ok, socket} =
             StepEvents.update(
               %{flash: %{}, socket: :parent, current_state: :overview},
               socket(%{})
             )

    assert socket.assigns.current_state == :overview
    refute Map.has_key?(socket.assigns, :flash)
  end
end
