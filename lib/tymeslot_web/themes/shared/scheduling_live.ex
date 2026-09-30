defmodule TymeslotWeb.Themes.Shared.SchedulingLive do
  @moduledoc """
  Shared LiveView macro for scheduling themes.

  A theme passes its wrapper component and one LiveComponent per step, and
  gets a `render/1` that handles every state the flow can be in:

      defmodule MyTheme.Scheduling.Live do
        alias MyTheme.Scheduling.Components.{
          BookingComponent,
          ConfirmationComponent,
          CustomQuestionsComponent,
          OverviewComponent,
          ScheduleComponent
        }

        alias MyTheme.Scheduling.Wrapper

        use TymeslotWeb.Themes.Shared.SchedulingLive,
          wrapper: &Wrapper.my_wrapper/1,
          steps: %{
            overview: OverviewComponent,
            schedule: ScheduleComponent,
            questions: CustomQuestionsComponent,
            booking: BookingComponent,
            confirmation: ConfirmationComponent
          }
      end

  The aliases must come before `use`: the options are expanded where `use` is
  written. One optional hook, a multi-clause `defp`:
  `handle_theme_event/3`, for events of the theme's own. A step template's
  `phx-click="theme:<name>"`, from any step, arrives as `<name>` with its
  params (the step on screen is `socket.assigns.current_state`), and so does
  one sent to the LiveView itself. An override replaces the default clause
  wholesale, and any visitor can send `theme:<anything>`, so it ends with a
  catch-all clause calling `super/3`, which logs the name and returns
  `{:noreply, socket}`; without one, an unknown name raises.

  A step event the flow does not handle is dropped with a warning
  (`StepEvents.log_ignored/3`), whatever the step, as is an event no hook
  clause takes, and a message nothing routes is logged and ignored
  (`InfoHandlers.handle_unexpected/2`).

  The macro also generates `handle_async/3` for the flow's `start_async/3`
  results (a week view's week of slots,
  `TymeslotWeb.Live.Scheduling.WeekSlots`); a theme writes none.
  """

  @steps [:overview, :schedule, :questions, :booking, :confirmation]

  defmacro __using__(opts) do
    opts = Keyword.validate!(opts, [:wrapper, :steps])
    wrapper = Keyword.fetch!(opts, :wrapper)
    steps = Keyword.fetch!(opts, :steps)
    validate_steps!(steps)
    validate_step_components!(steps, __CALLER__)

    quote do
      use TymeslotWeb, :live_view

      alias TymeslotWeb.Live.Scheduling.WeekSlots
      alias TymeslotWeb.Themes.Shared.{EventHandlers, InfoHandlers, PathHandlers}
      alias TymeslotWeb.Themes.Shared.LiveHelpers.{Mount, Tracking}
      alias TymeslotWeb.Themes.Shared.{SchedulingFlow, SchedulingPage, StepEvents}

      @impl Phoenix.LiveView
      def mount(params, _session, socket) do
        socket =
          socket
          |> Mount.mount_scheduling_view(params)
          |> Tracking.assign_tracking(params)

        {:ok, socket}
      end

      @impl Phoenix.LiveView
      def render(assigns), do: SchedulingPage.render(assigns, unquote(wrapper), unquote(steps))

      @impl Phoenix.LiveView
      def handle_params(params, _url, socket), do: Mount.handle_scheduling_params(socket, params)

      # A theme's own event (`theme:<name>`, relayed untouched by the step
      # relays) goes to the theme's hook without its prefix, from any step;
      # the flow never sees it, so it cannot stand in for a canonical event.
      @impl Phoenix.LiveView
      def handle_info({:step_event, _step, "theme:" <> name, params}, socket),
        do: handle_theme_event(name, params, socket)

      def handle_info({:step_event, step, event, data}, socket) do
        case SchedulingFlow.handle_step_event(socket, step, event, data) do
          :unhandled ->
            StepEvents.log_ignored(socket.assigns, step, event)
            {:noreply, socket}

          reply ->
            reply
        end
      end

      # Must stay last: a public page cannot afford to raise on a message it
      # has no clause for. A theme has no hook here: `defoverridable` replaces
      # a function's clauses wholesale, so one theme-specific clause would
      # silently drop slot loading, calendar refresh and payment handling.
      def handle_info(message, socket) do
        case InfoHandlers.route(message, socket) do
          :unhandled -> InfoHandlers.handle_unexpected(socket, message)
          reply -> reply
        end
      end

      # The flow's `start_async/3` results, forwarded by the dispatcher: a
      # week view's week of slots is the only one.
      @impl Phoenix.LiveView
      def handle_async(name, result, socket) do
        case WeekSlots.handle_async(name, result, socket) do
          :unhandled -> {:noreply, socket}
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

      # Step navigation belongs to the flow, not to a theme: a clause of
      # `handle_theme_event/3` would be replaced wholesale by a theme's own
      # override of that hook.
      def handle_event("navigate_to_step", params, socket),
        do: SchedulingFlow.navigate_to_step(socket, params)

      def handle_event("theme:" <> name, params, socket),
        do: handle_theme_event(name, params, socket)

      def handle_event(event, params, socket), do: handle_theme_event(event, params, socket)

      # Extension point. Override with multi-clause defps ending in a
      # catch-all clause that calls super/3, so an unknown name is logged.
      defp handle_theme_event(event, _params, socket) do
        StepEvents.log_ignored(socket.assigns, socket.assigns[:current_state], event)
        {:noreply, socket}
      end

      defoverridable handle_theme_event: 3
    end
  end

  defp validate_steps!({:%{}, _meta, pairs}) do
    keys = Keyword.keys(pairs)

    case {@steps -- keys, keys -- @steps} do
      {[], []} ->
        :ok

      {[], unknown} ->
        raise ArgumentError,
              "use SchedulingLive got steps it does not know: #{inspect(unknown)}; " <>
                "the steps are #{inspect(@steps)}"

      {missing, _unknown} ->
        raise ArgumentError,
              "use SchedulingLive needs a component for every step; missing: #{inspect(missing)}"
    end
  end

  defp validate_steps!(other) do
    raise ArgumentError,
          "use SchedulingLive expects :steps as a literal map of step => component, got: " <>
            Macro.to_string(other)
  end

  # Checked here, while the theme compiles, rather than in an `@after_verify`
  # callback: an exception raised there crashes the compiler's checker process
  # instead of surfacing from `Code.compile_quoted/1`, so no test could see it.
  # The aliases are expanded as if inside a function, so the theme's `live.ex`
  # keeps a runtime dependency on its step components rather than a
  # compile-time one: the components import `StepEvents`, and a compile-time
  # edge to them would pull that chain into every theme's recompilation.
  defp validate_step_components!({:%{}, _meta, pairs}, caller) do
    Enum.each(pairs, fn {step, alias_ast} ->
      module = Macro.expand(alias_ast, %{caller | function: {:render, 1}})

      unless live_component?(module) do
        raise CompileError,
          file: caller.file,
          line: caller.line,
          description:
            "use SchedulingLive needs a LiveComponent for step #{inspect(step)}, " <>
              "got #{inspect(module)}, which is not a loaded LiveComponent"
      end
    end)
  end

  defp live_component?(module) do
    is_atom(module) and match?({:module, _}, Code.ensure_compiled(module)) and
      function_exported?(module, :__live__, 0) and module.__live__()[:kind] == :component
  end
end
