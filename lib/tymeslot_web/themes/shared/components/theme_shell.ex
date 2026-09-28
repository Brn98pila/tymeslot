defmodule TymeslotWeb.Themes.Shared.Components.ThemeShell do
  @moduledoc """
  The page chrome every theme's wrapper renders, in this order: the
  organiser's customisation as a `<style>` block on `:root`, the theme's
  background (`:background` slot), then the theme grid holding the content
  area (owner-preview notice, language switcher, the step itself) and the
  extensions configured under `:theme_extensions`, which occupy the grid's
  footer row.

  A wrapper keeps only what is its own: its background markup and its class
  names, passed as `class` (outermost element), `grid_class` and `grid_style`
  (the theme grid) and `language_class` (the language switcher's container),
  plus its theme's `theme_id`. The grid always carries the `booker-page` hook
  class that the shared embed rules (`shared/embed.css`) size to content, and
  a hidden language switcher's container carries `theme-shell__language--hidden`
  next to Tailwind's `hidden`, for a theme that must hide it with its own rule. The extensions receive this component's
  assigns: `theme_id`, `organizer_user_id`, `should_show_branding`, and
  `demo_mode` when the page assigned one.
  """

  use Phoenix.Component

  alias Tymeslot.Locales
  alias TymeslotWeb.Layouts

  import TymeslotWeb.Components.LanguageSwitcher, only: [language_switcher: 1]
  import TymeslotWeb.Themes.Shared.Components.PreviewNotice, only: [banner: 1]

  attr :class, :any, required: true, doc: "classes on the outermost element"
  attr :grid_class, :any, required: true, doc: "classes on the theme grid"
  attr :grid_style, :string, default: nil, doc: "inline style on the theme grid"
  attr :language_class, :any, required: true, doc: "classes on the language switcher's container"
  attr :theme_id, :string, required: true, doc: "the rendering theme's catalogue id"
  attr :demo_mode, :boolean, doc: "handed to the extensions only when given"
  attr :custom_css, :string, default: nil
  attr :locale, :string, default: nil
  attr :language_dropdown_open, :boolean, default: nil
  attr :show_language_switcher, :boolean, default: false
  attr :owner_preview, :boolean, default: false
  attr :organizer_user_id, :integer, default: nil
  attr :should_show_branding, :boolean, default: false

  slot :background, doc: "the theme's background, rendered before the grid"
  slot :inner_block, required: true

  @spec theme_shell(map()) :: Phoenix.LiveView.Rendered.t()
  def theme_shell(assigns) do
    ~H"""
    <div class={@class} data-locale={@locale}>
      <%= if @custom_css not in [nil, ""] do %>
        <style type="text/css">
          :root {
            <%= Phoenix.HTML.raw(@custom_css) %>
          }
        </style>
      <% end %>

      {render_slot(@background)}

      <div class={["booker-page", @grid_class]} {grid_style(@grid_style)}>
        <div class="content-area">
          <.banner owner_preview={@owner_preview} />
          <%= if @locale && @language_dropdown_open != nil do %>
            <div class={[
              @language_class,
              @show_language_switcher && "visible",
              !@show_language_switcher && "hidden theme-shell__language--hidden"
            ]}>
              <.language_switcher
                locale={@locale}
                locales={Locales.supported()}
                dropdown_open={@language_dropdown_open}
              />
            </div>
          <% end %>

          {render_slot(@inner_block)}
        </div>

        {Layouts.render_theme_extensions(assigns)}
      </div>
    </div>
    """
  end

  # A theme without a grid style gets no `style` attribute at all, rather than
  # the empty one HEEx renders for `style={nil}`.
  defp grid_style(nil), do: []
  defp grid_style(style), do: [style: style]
end
