defmodule TymeslotWeb.Themes.Shared.SchedulingLive do
  @moduledoc """
  Shared LiveView macro for scheduling themes.

  Generates the LiveView callbacks for the booking flow, each delegating to a
  plain module: `LiveHelpers.Mount` for mounting and URL parameters,
  `SchedulingFlow` for step events and navigation, `InfoHandlers` for the
  mailbox. Themes `use` this macro and only need to define:

  - `render/1` — wrapper component and step layout
  - `handle_theme_event/3` (optional) — for theme-specific events
  - `handle_theme_schedule_event/3` (optional) — for theme-specific schedule events
  - `handle_theme_info/2` (optional) — for theme-specific `handle_info/2` messages

  ## Example

      defmodule MyTheme.Scheduling.Live do
        use TymeslotWeb.Themes.Shared.SchedulingLive, theme_id: "3"

        alias MyTheme.Scheduling.Wrapper

        @impl Phoenix.LiveView
        def render(assigns) do
          ~H\"""
          <Wrapper.my_wrapper ...>
            ...
          </Wrapper.my_wrapper>
          \"""
        end
      end
  """

  defmacro __using__(opts) do
    theme_id = Keyword.fetch!(opts, :theme_id)

    quote do
      use TymeslotWeb, :live_view

      alias TymeslotWeb.Themes.Shared.Components.ErrorComponent
      alias TymeslotWeb.Themes.Shared.{EventHandlers, InfoHandlers, PathHandlers, SchedulingFlow}
      alias TymeslotWeb.Themes.Shared.LiveHelpers.{Mount, Tracking}

      @theme_id unquote(theme_id)

      @impl Phoenix.LiveView
      def mount(params, _session, socket) do
        socket =
          socket
          |> Mount.mount_scheduling_view(params, @theme_id)
          |> Tracking.assign_tracking(params)

        {:ok, socket}
      end

      @impl Phoenix.LiveView
      def handle_params(params, _url, socket), do: Mount.handle_scheduling_params(socket, params)

      @impl Phoenix.LiveView
      def handle_info({:step_event, step, event, data}, socket) do
        case SchedulingFlow.handle_step_event(socket, step, event, data) do
          :unhandled when step == :schedule -> handle_theme_schedule_event(socket, event, data)
          :unhandled -> {:noreply, socket}
          reply -> reply
        end
      end

      # Must stay last: a public page cannot afford to raise on a message it
      # has no clause for. The theme gets a message only once the flow has
      # declined it, through `handle_theme_info/2` rather than an overridable
      # `handle_info/2`: `defoverridable` replaces a function's clauses
      # wholesale, so one theme-specific clause would silently drop slot
      # loading, calendar refresh and payment handling.
      def handle_info(message, socket) do
        case InfoHandlers.route(message, socket) do
          :unhandled -> handle_theme_info(message, socket)
          reply -> reply
        end
      end

      @impl Phoenix.LiveView
      def handle_event("toggle_language_dropdown", _params, socket),
        do: EventHandlers.handle_toggle_language_dropdown(socket)

      def handle_event("close_language_dropdown", _params, socket),
        do: EventHandlers.handle_close_language_dropdown(socket)

      def handle_event("change_locale", %{"locale" => locale}, socket),
        do: EventHandlers.handle_change_locale(socket, locale, PathHandlers)

      def handle_event(event, params, socket), do: handle_theme_event(event, params, socket)

      defp handle_theme_event("navigate_to_step", params, socket),
        do: SchedulingFlow.navigate_to_step(socket, params)

      # Extension points. Override with multi-clause defps; a theme override of
      # `handle_theme_info/2` should end with a clause calling
      # `InfoHandlers.handle_unexpected/2`, as this default does.
      defp handle_theme_event(_event, _params, socket), do: {:noreply, socket}
      defp handle_theme_schedule_event(socket, _event, _data), do: {:noreply, socket}
      defp handle_theme_info(message, socket), do: InfoHandlers.handle_unexpected(socket, message)

      defoverridable handle_theme_event: 3,
                     handle_theme_schedule_event: 3,
                     handle_theme_info: 2
    end
  end
end
