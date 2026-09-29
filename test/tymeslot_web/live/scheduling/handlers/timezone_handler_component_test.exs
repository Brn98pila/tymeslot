defmodule TymeslotWeb.Live.Scheduling.Handlers.TimezoneHandlerComponentTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :utils

  alias Phoenix.LiveView.Socket
  alias TymeslotWeb.Live.Scheduling.Handlers.TimezoneHandlerComponent

  test "handle_timezone_change updates state" do
    socket = %Socket{
      assigns: %{
        __changed__: %{},
        user_timezone: "UTC",
        selected_time: "10:00",
        available_slots: ["10:00"],
        timezone_dropdown_open: true,
        timezone_search: "Lon",
        selected_date: nil
      }
    }

    {:ok, updated} = TimezoneHandlerComponent.handle_timezone_change(socket, "Europe/London")
    assert updated.assigns.user_timezone == "Europe/London"
    assert updated.assigns.selected_time == nil
    assert updated.assigns.timezone_dropdown_open == false
    assert updated.assigns.timezone_search == ""
  end

  test "handle_timezone_change leaves reloading the selected day's slots to its caller" do
    # The caller first decides whether the day stays selected in the new zone;
    # a reload queued here would fetch slots for a day about to be dropped.
    socket = %Socket{
      assigns: %{
        __changed__: %{},
        user_timezone: "UTC",
        selected_date: "2024-01-01",
        selected_duration: 30,
        duration: nil,
        selected_time: "10:00",
        available_slots: ["10:00"],
        timezone_dropdown_open: true,
        timezone_search: "Lon"
      }
    }

    {:ok, updated} = TimezoneHandlerComponent.handle_timezone_change(socket, "Europe/London")

    assert %{user_timezone: "Europe/London", selected_time: nil, available_slots: []} =
             updated.assigns

    refute_received {:fetch_available_slots, _date, _duration, _timezone}
  end

  test "handle_timezone_change keeps the time and slots when the zone in use is picked again" do
    socket = %Socket{
      assigns: %{
        __changed__: %{},
        user_timezone: "Europe/London",
        selected_date: "2024-01-01",
        selected_time: "10:00",
        available_slots: ["10:00"],
        timezone_dropdown_open: true,
        timezone_search: "Lon"
      }
    }

    {:ok, updated} = TimezoneHandlerComponent.handle_timezone_change(socket, "Europe/London")

    assert %{selected_time: "10:00", available_slots: ["10:00"], timezone_dropdown_open: false} =
             updated.assigns
  end
end
