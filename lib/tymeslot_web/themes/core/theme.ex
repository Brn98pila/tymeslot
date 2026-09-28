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
      `Payment.Processing` and `Payment.Cancelled`.

  Every render callback is overridable; an override carries
  `@impl TymeslotWeb.Themes.Core.Behaviour` like any other callback. A
  conventional module that neither exists nor is overridden is an
  undefined-module warning, so a missing page fails the build rather than a
  request.
  """

  @doc false
  defmacro __using__(opts) do
    live_view = Keyword.fetch!(opts, :live_view)
    preview_image = Keyword.fetch!(opts, :preview_image)
    {description, domain} = translatable!(Keyword.fetch!(opts, :description))
    reschedule = conventional(__CALLER__.module, ["Meeting", "Reschedule"])
    cancel = conventional(__CALLER__.module, ["Meeting", "Cancel"])
    cancel_confirmed = conventional(__CALLER__.module, ["Meeting", "CancelConfirmed"])
    poll = conventional(__CALLER__.module, ["Poll", "Voting"])
    processing = conventional(__CALLER__.module, ["Payment", "Processing"])
    cancelled = conventional(__CALLER__.module, ["Payment", "Cancelled"])

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

      defoverridable render_meeting_action: 2, render_poll_action: 1, render_payment_page: 2
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
