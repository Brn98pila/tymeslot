defmodule TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.PalettePanel do
  @moduledoc """
  The dashboard panel for an `Options.Palette` group: the group's preset
  schemes and a custom seed colour.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.ThemeCustomizations.Options.Palette
  alias TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.Panel

  import TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.CurrentIndicator,
    only: [current_indicator: 1]

  import TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.Pickers.ColourPickerWidget,
    only: [colour_picker_widget: 1]

  @behaviour Panel

  @impl Panel
  def render(assigns) do
    ~H"""
    <div class="card-glass">
      <div class="flex flex-col sm:flex-row sm:items-center justify-between mb-8 gap-4">
        <div>
          <h3 class="text-token-xl font-black text-tymeslot-900 tracking-tight">
            {dgettext("dashboard_appearance", "Color Palette")}
          </h3>
          <p class="text-token-sm text-tymeslot-500 font-bold mt-1">
            {dgettext(
              "dashboard_appearance",
              "Select the primary colors for your booking page interface."
            )}
          </p>
        </div>

        <div class="flex flex-wrap items-center gap-3">
          <% current_scheme = Palette.resolve(@customization.settings) %>
          <% custom_selected = not is_nil(@customization.settings["custom_palette_seed"]) %>
          <%= if current_scheme do %>
            <.current_indicator
              swatches={[
                current_scheme.colors.primary,
                current_scheme.colors.secondary,
                current_scheme.colors.accent
              ]}
              label={current_scheme.name}
              code={
                if custom_selected,
                  do: String.upcase(@customization.settings["custom_palette_seed"])
              }
              highlighted={custom_selected}
            />
          <% end %>
          <button
            type="button"
            phx-click="theme:toggle_palette_picker"
            phx-target={@myself}
            aria-expanded={to_string(@palette_picker_open)}
            aria-controls="custom-palette-picker"
            class={[
              "flex items-center gap-2 px-3.5 py-2 rounded-token-xl border-2 text-token-2xs font-black uppercase tracking-widest transition-all duration-300",
              if(@palette_picker_open,
                do:
                  "bg-turquoise-50 border-turquoise-300 text-turquoise-700 shadow-sm shadow-turquoise-500/10",
                else:
                  "bg-tymeslot-50 border-transparent text-tymeslot-600 hover:bg-tymeslot-100 hover:border-tymeslot-200"
              )
            ]}
          >
            <.icon name="hero-swatch-mini" class="w-4 h-4" />
            <span>{dgettext("dashboard_appearance", "Custom")}</span>
            <.icon
              name="hero-chevron-down-mini"
              class={"w-4 h-4 transition-transform duration-300 #{if @palette_picker_open, do: "rotate-180"}"}
            />
          </button>
        </div>
      </div>

      <div class="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-4 gap-4">
        <% active_scheme_id =
          if is_nil(@customization.settings["custom_palette_seed"]),
            do: @customization.settings["color_scheme"] %>
        <%!-- Sorted by id, the order the dashboard has always shown; the group's
        own order is onboarding's.
        The param is named `choice` rather than `value`, because LiveView's
        client serialisation reads a button's native `value` IDL property and
        would overwrite `phx-value-value` with the empty string. --%>
        <%= for {scheme_id, scheme} <- Enum.sort_by(Palette.schemes(@group), &elem(&1, 0)) do %>
          <button
            type="button"
            class={[
              "group/scheme relative flex flex-col items-center p-4 rounded-token-2xl border-2 transition-all duration-300",
              if(active_scheme_id == scheme_id,
                do: "bg-turquoise-50 border-turquoise-400 shadow-xl shadow-turquoise-500/10",
                else: "bg-white border-tymeslot-50 hover:border-turquoise-200 hover:shadow-lg"
              )
            ]}
            phx-click="theme:set_option"
            phx-value-option={@group.key}
            phx-value-field="scheme"
            phx-value-choice={scheme_id}
            phx-target={@myself}
          >
            <div class="flex items-center gap-2 mb-4 bg-tymeslot-50/50 p-2 rounded-token-xl group-hover/scheme:scale-110 transition-transform">
              <div
                class="w-6 h-6 rounded-full shadow-sm border border-white"
                style={"background-color: #{scheme.colors.primary}"}
              >
              </div>
              <div
                class="w-6 h-6 rounded-full shadow-sm border border-white"
                style={"background-color: #{scheme.colors.secondary}"}
              >
              </div>
              <div
                class="w-6 h-6 rounded-full shadow-sm border border-white"
                style={"background-color: #{scheme.colors.accent}"}
              >
              </div>
            </div>
            <p class={[
              "text-token-sm font-black uppercase tracking-widest transition-colors",
              if(active_scheme_id == scheme_id,
                do: "text-turquoise-700",
                else: "text-tymeslot-400 group-hover/scheme:text-tymeslot-600"
              )
            ]}>
              {scheme.name}
            </p>

            <%= if active_scheme_id == scheme_id do %>
              <div class="absolute top-2 right-2 w-6 h-6 bg-turquoise-500 text-white rounded-full flex items-center justify-center shadow-lg">
                <.icon name="hero-check-mini" class="w-4 h-4" />
              </div>
            <% end %>
          </button>
        <% end %>
      </div>

      <%= if not is_nil(@customization.settings["custom_palette_seed"]) and @palette_picker_open do %>
        <div class="mt-6 animate-fade-in-up rounded-token-2xl border-2 border-tymeslot-50 bg-tymeslot-50/50 p-4">
          <.colour_picker_widget
            id="custom-palette-picker"
            target={@myself}
            initial_hex={@customization.settings["custom_palette_seed"]}
            commit_event="theme:set_option"
            commit_params={%{option: @group.key, field: "seed"}}
          />
        </div>
      <% end %>
    </div>
    """
  end
end
