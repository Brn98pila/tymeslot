defmodule TymeslotWeb.Themes.Core.Theme do
  @moduledoc """
  `use` this to define a booking theme module.

      defmodule TymeslotWeb.Themes.Quill.Theme do
        use TymeslotWeb.Themes.Core.Theme,
          live_view: TymeslotWeb.Themes.Quill.Scheduling.Live,
          preview_image: "/images/ui/theme-previews/quill-theme-preview.webp",
          description: dgettext_noop("dashboard_appearance", "…")
      end

  It declares `TymeslotWeb.Themes.Core.Behaviour` and generates:

    * `live_view_module/0`, returning `:live_view`;
    * `metadata/0`, returning `:preview_image` and `:description` translated
      into the current locale. The description must be a `dgettext_noop/2`
      call, so extraction registers it and the lookup knows its domain;
    * the render callbacks, dispatching to the conventional modules under the
      theme's namespace, each with a `render/1`: `Meeting.Reschedule`,
      `Meeting.Cancel`, `Meeting.CancelConfirmed`, `Poll.Voting`,
      `Payment.Processing` and `Payment.Cancelled`; or, when `:page_shell`
      names a function component (`page_shell: &MyTheme.Pages.page_shell/1`),
      the six pages from `TymeslotWeb.Themes.Shared.DefaultPages`, the
      shared bodies inside that shell: a theme then writes no page modules
      at all;
    * `onboarding_preview/1`, defaulting to the generic mock in
      `TymeslotWeb.OnboardingLive.PreviewParts`;
    * `option_panels/0`, returning `:option_panels` (default `%{}`): the
      dashboard panels for the theme's own option groups,
      `%{group_module => panel_module}`.

  Every render callback is overridable; an override carries
  `@impl TymeslotWeb.Themes.Core.Behaviour` like any other callback. A
  conventional module that neither exists nor is overridden is an
  undefined-module warning, so a missing page fails the build rather than a
  request.
  """

  # Aliased here, outside the quote, so the generated default expands to the
  # full module name and nothing is aliased inside the theme module.
  alias TymeslotWeb.OnboardingLive.PreviewParts
  alias TymeslotWeb.Themes.Shared.DefaultPages

  @doc false
  defmacro __using__(opts) do
    live_view = Keyword.fetch!(opts, :live_view)
    preview_image = Keyword.fetch!(opts, :preview_image)
    {description, domain} = translatable!(Keyword.fetch!(opts, :description))
    renders = renders(Keyword.get(opts, :page_shell), __CALLER__.module)
    option_panels = Keyword.get(opts, :option_panels, Macro.escape(%{}))

    quote do
      @behaviour TymeslotWeb.Themes.Core.Behaviour

      use Gettext, backend: TymeslotWeb.Gettext

      @impl TymeslotWeb.Themes.Core.Behaviour
      def live_view_module, do: unquote(live_view)

      @impl TymeslotWeb.Themes.Core.Behaviour
      def metadata do
        %{
          preview_image: unquote(preview_image),
          description:
            Gettext.dgettext(TymeslotWeb.Gettext, unquote(domain), unquote(description))
        }
      end

      unquote(renders)

      @impl TymeslotWeb.Themes.Core.Behaviour
      def onboarding_preview(assigns), do: PreviewParts.generic(assigns)

      @impl TymeslotWeb.Themes.Core.Behaviour
      def option_panels, do: unquote(option_panels)

      defoverridable render_meeting_action: 2,
                     render_poll_action: 1,
                     render_payment_page: 2,
                     onboarding_preview: 1
    end
  end

  # With a :page_shell, the shared bodies inside the theme's shell; without
  # one, the conventional modules beside the theme module.
  defp renders(nil, theme_module) do
    reschedule = conventional(theme_module, ["Meeting", "Reschedule"])
    cancel = conventional(theme_module, ["Meeting", "Cancel"])
    cancel_confirmed = conventional(theme_module, ["Meeting", "CancelConfirmed"])
    poll = conventional(theme_module, ["Poll", "Voting"])
    processing = conventional(theme_module, ["Payment", "Processing"])
    cancelled = conventional(theme_module, ["Payment", "Cancelled"])

    quote do
      @impl TymeslotWeb.Themes.Core.Behaviour
      def render_meeting_action(assigns, :reschedule), do: unquote(reschedule).render(assigns)
      def render_meeting_action(assigns, :cancel), do: unquote(cancel).render(assigns)

      def render_meeting_action(assigns, :cancel_confirmed),
        do: unquote(cancel_confirmed).render(assigns)

      def render_meeting_action(_assigns, action),
        do: raise("Unsupported meeting action: #{action}")

      @impl TymeslotWeb.Themes.Core.Behaviour
      def render_poll_action(assigns), do: unquote(poll).render(assigns)

      @impl TymeslotWeb.Themes.Core.Behaviour
      def render_payment_page(assigns, :processing), do: unquote(processing).render(assigns)
      def render_payment_page(assigns, :cancelled), do: unquote(cancelled).render(assigns)
    end
  end

  defp renders(page_shell, _theme_module) do
    quote do
      @impl TymeslotWeb.Themes.Core.Behaviour
      def render_meeting_action(assigns, action),
        do: DefaultPages.meeting_action(assigns, action, unquote(page_shell))

      @impl TymeslotWeb.Themes.Core.Behaviour
      def render_poll_action(assigns), do: DefaultPages.poll(assigns, unquote(page_shell))

      @impl TymeslotWeb.Themes.Core.Behaviour
      def render_payment_page(assigns, page),
        do: DefaultPages.payment(assigns, page, unquote(page_shell))
    end
  end

  # The conventional module beside the theme module:
  # `TymeslotWeb.Themes.Quill.Theme` and `["Poll", "Voting"]` give
  # `TymeslotWeb.Themes.Quill.Poll.Voting`. `Module.safe_concat/1` cannot be
  # used, since the compiler may not have loaded that module yet. The segments
  # are the fixed convention above, never user input, so the atoms are bounded.
  defp conventional(theme_module, segments) do
    theme_module
    |> Module.split()
    |> Enum.drop(-1)
    |> Kernel.++(segments)
    # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
    |> Module.concat()
  end

  defp translatable!({:dgettext_noop, _meta, [domain, msgid]} = ast)
       when is_binary(domain) and is_binary(msgid),
       do: {ast, domain}

  defp translatable!(other) do
    raise ArgumentError,
          "the :description option of use TymeslotWeb.Themes.Core.Theme must be a " <>
            "dgettext_noop/2 call with a literal domain and msgid, got: " <>
            Macro.to_string(other)
  end
end
