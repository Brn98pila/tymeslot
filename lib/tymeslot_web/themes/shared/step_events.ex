defmodule TymeslotWeb.Themes.Shared.StepEvents do
  @moduledoc """
  Theme-independent event handling for the booking step components.

  Every theme's overview, schedule, booking and confirmation components
  delegate `update/2` and `handle_event/3` here, so the event names a
  template may use, and what each one tells the LiveView, are the same in
  every theme. Events are relayed to the scheduling LiveView as
  `{:step_event, step, event, data}` under the step on screen, which is
  `:current_state` (every step component receives the LiveView's assigns).
  The custom-questions step has its own module,
  `Shared.CustomQuestions.Events`.

  The canonical events: `select_duration`, `next_step` (overview);
  `select_date`, `select_time`, `toggle_hour`, `change_timezone`,
  `search_timezone`, `toggle_timezone_dropdown`, `close_timezone_dropdown`,
  `prev_month`, `next_month`, `prev_week`, `next_week`, `back_step`,
  `next_step` (schedule); `validate`, `field_blur`, `submit`, `back_step`,
  `select_location`, `select_video_provider`, `location_phone_change`,
  `toggle_guests`, `close_guests`, `guest_input_change`, `add_guest`,
  `remove_guest` (booking); `schedule_another` (confirmation). Anything else
  is ignored.
  """

  import Phoenix.Component, only: [assign: 2, assign: 3]

  alias Phoenix.LiveView.Socket
  alias TymeslotWeb.Themes.Shared.BookingLocation

  @doc "Takes the LiveView's assigns, minus the ones a component cannot hold."
  @spec update(map(), Socket.t()) :: {:ok, Socket.t()}
  def update(assigns, socket), do: {:ok, assign(socket, Map.drop(assigns, [:flash, :socket]))}

  @doc "Relays a canonical step event to the scheduling LiveView."
  @spec handle_event(String.t(), map(), Socket.t()) :: {:noreply, Socket.t()}
  # Set submitting state immediately for instant UI feedback — but only when
  # the location picker has an answer the LiveView will accept. An incomplete
  # one is refused without changing any assign this component renders, so a
  # flag set here would have nothing to clear it again.
  def handle_event("submit", %{"booking" => booking_params}, socket) do
    socket
    |> assign(:submitting, BookingLocation.complete?(socket.assigns))
    |> relay(:submit, booking_params)
  end

  def handle_event(event, params, socket) do
    case message(event, params) do
      {name, data} -> relay(socket, name, data)
      :ignore -> {:noreply, socket}
    end
  end

  defp relay(socket, name, data) do
    send(self(), {:step_event, socket.assigns.current_state, name, data})
    {:noreply, socket}
  end

  defp message("select_duration", %{"duration" => duration}), do: {:select_duration, duration}
  defp message("next_step", _params), do: {:next_step, nil}
  defp message("back_step", _params), do: {:back_step, nil}
  defp message("select_date", %{"date" => date}), do: {:select_date, date}
  defp message("select_time", %{"time" => time}), do: {:select_time, time}
  defp message("toggle_hour", %{"hour" => hour}), do: {:toggle_hour, hour}
  defp message("change_timezone", %{"timezone" => timezone}), do: {:change_timezone, timezone}
  defp message("search_timezone", params), do: {:search_timezone, params}
  defp message("toggle_timezone_dropdown", _params), do: {:toggle_timezone_dropdown, nil}
  defp message("close_timezone_dropdown", _params), do: {:close_timezone_dropdown, nil}
  defp message("prev_month", _params), do: {:prev_month, nil}
  defp message("next_month", _params), do: {:next_month, nil}
  defp message("prev_week", _params), do: {:prev_week, nil}
  defp message("next_week", _params), do: {:next_week, nil}
  defp message("validate", %{"booking" => booking_params}), do: {:validate, booking_params}
  defp message("field_blur", %{"field" => field}), do: {:field_blur, field}
  defp message("select_location", %{"id" => id}), do: {:select_location, id}
  defp message("select_video_provider", %{"id" => id}), do: {:select_video_provider, id}

  defp message("location_phone_change", params),
    do: {:location_phone, params["location_phone"] || ""}

  defp message("toggle_guests", _params), do: {:toggle_guests, nil}
  defp message("close_guests", _params), do: {:close_guests, nil}
  defp message("guest_input_change", params), do: {:guest_input, params["guest_email"] || ""}
  defp message("add_guest", params), do: {:add_guest, params["guest_email"] || ""}
  defp message("remove_guest", %{"email" => email}), do: {:remove_guest, email}
  defp message("schedule_another", _params), do: {:schedule_another, nil}
  defp message(_event, _params), do: :ignore
end
