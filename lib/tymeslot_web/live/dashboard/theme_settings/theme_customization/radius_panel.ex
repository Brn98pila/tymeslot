defmodule TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.RadiusPanel do
  @moduledoc """
  The dashboard panel for an `Options.Radius` group: sharp, soft or round
  corners, each shown with a sample of its control corner. It keeps no UI
  state.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext
  use TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.Panel

  alias Tymeslot.ThemeCustomizations.Options.Radius
  alias TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.Panel

  @impl Panel
  def render(assigns) do
    assigns =
      assign(assigns, :choice, Radius.choice(assigns.customization.settings, assigns.group))

    ~H"""
    <div class="card-glass" data-testid="radius-panel">
      <div class="mb-8">
        <h3 class="text-token-xl font-black text-tymeslot-900 tracking-tight">
          {dgettext("dashboard_appearance", "Corners")}
        </h3>
        <p class="text-token-sm text-tymeslot-500 font-bold mt-1">
          {dgettext(
            "dashboard_appearance",
            "How rounded the buttons and cards on your booking page are."
          )}
        </p>
      </div>

      <div class="grid grid-cols-1 sm:grid-cols-3 gap-4">
        <button
          :for={radius <- Radius.choices()}
          type="button"
          class={[
            "flex flex-col items-center gap-3 p-5 rounded-token-2xl border-2 transition-all duration-300",
            if(@choice == radius,
              do: "bg-turquoise-50 border-turquoise-400 shadow-xl shadow-turquoise-500/10",
              else: "bg-white border-tymeslot-50 hover:border-turquoise-200 hover:shadow-lg"
            )
          ]}
          phx-click="theme:set_option"
          phx-value-option={@group.key}
          phx-value-field="radius"
          phx-value-choice={radius}
          phx-target={@myself}
          aria-pressed={to_string(@choice == radius)}
        >
          <span
            class={[
              "block w-12 h-8 border-2",
              if(@choice == radius, do: "border-turquoise-500", else: "border-tymeslot-300")
            ]}
            style={"border-radius: #{Radius.lengths(radius).control}"}
          ></span>
          <span class={[
            "text-token-sm font-black uppercase tracking-widest",
            if(@choice == radius, do: "text-turquoise-700", else: "text-tymeslot-500")
          ]}>
            {label(radius)}
          </span>
        </button>
      </div>
    </div>
    """
  end

  defp label("sharp"), do: dgettext("dashboard_appearance", "Sharp")
  defp label("soft"), do: dgettext("dashboard_appearance", "Soft")
  defp label("round"), do: dgettext("dashboard_appearance", "Round")
end
