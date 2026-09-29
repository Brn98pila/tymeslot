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
  written. Optional hooks, each a multi-clause `defp`:

  - `handle_theme_event/3` for events of the theme's own: a step template's
    `phx-click="theme:<name>"` arrives as `<name>` (with its params), and so
    does one sent to the LiveView itself
  - `handle_theme_schedule_event/3` for the schedule step's `theme:<name>`
    events, as `(socket, name, params)`, and for schedule events the flow
    does not know
  - `handle_theme_info/2` for messages of the theme's own

  An override replaces the hook's default clause wholesale, and any visitor
  can send `theme:<anything>`, so an override of `handle_theme_event/3` or
  `handle_theme_schedule_event/3` ends with a catch-all clause returning
  `{:noreply, socket}`; without one, an unknown name raises.
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

      alias TymeslotWeb.Themes.Shared.{EventHandlers, InfoHandlers, PathHandlers}
      alias TymeslotWeb.Themes.Shared.LiveHelpers.{Mount, Tracking}
      alias TymeslotWeb.Themes.Shared.{SchedulingFlow, SchedulingPage}

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
      # relays) goes to the theme's hook without its prefix; the flow never
      # sees it, so it cannot stand in for a canonical event.
      @impl Phoenix.LiveView
      def handle_info({:step_event, :schedule, "theme:" <> name, params}, socket),
        do: handle_theme_schedule_event(socket, name, params)

      def handle_info({:step_event, _step, "theme:" <> name, params}, socket),
        do: handle_theme_event(name, params, socket)

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

      # Step navigation belongs to the flow, not to a theme: a clause of
      # `handle_theme_event/3` would be replaced wholesale by a theme's own
      # override of that hook.
      def handle_event("navigate_to_step", params, socket),
        do: SchedulingFlow.navigate_to_step(socket, params)

      def handle_event("theme:" <> name, params, socket),
        do: handle_theme_event(name, params, socket)

      def handle_event(event, params, socket), do: handle_theme_event(event, params, socket)

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
