defmodule TymeslotWeb.OnboardingLive.ChooseThemeStep do
  @moduledoc """
  Theme selection step for the onboarding flow.

  Lets the user pick a booking theme and accent colour scheme, and preview
  their *real* booking page full-screen. This step only appears once a
  calendar is connected — at that point the public page is ready, so the
  preview reflects the live page rather than a mock.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  import TymeslotWeb.Components.CoreComponents, only: [icon: 1]

  alias Tymeslot.ThemeCustomizations.Presets
  alias Tymeslot.Themes.Catalog
  alias TymeslotWeb.OnboardingLive.PreviewParts
  alias TymeslotWeb.Themes.Core.ThemeInfo

  # Stable display order for the colour-scheme swatches.
  @scheme_order ~w(default turquoise purple sunset ocean forest rose monochrome)

  @doc """
  Renders the theme + colour picker with a live full-page preview button.

  ## Attributes

  * `profile` - The user's profile struct (carries the selected `booking_theme`)
  * `theme_options` - List of `{name, id}` booking theme tuples
  * `color_scheme` - The currently selected colour-scheme id
  """
  attr :profile, :map, required: true
  attr :theme_options, :list, required: true
  attr :color_scheme, :string, required: true

  @spec choose_theme_step(map()) :: Phoenix.LiveView.Rendered.t()
  def choose_theme_step(assigns) do
    color_schemes = Presets.get_color_schemes()

    primary =
      color_schemes
      |> Map.get(assigns.color_scheme, %{})
      |> Map.get(:colors, %{})
      |> Map.get(:primary, "#14b8a6")

    assigns =
      assigns
      |> assign(:color_schemes, color_schemes)
      |> assign(:primary, primary)

    ~H"""
    <div class="onboarding-form">
      <%!-- Booking theme --%>
      <div class="onboarding-form-group">
        <label class="label">{dgettext("onboarding_wizard", "Your booking theme")}</label>
        <p class="onboarding-form-helper">
          {dgettext("onboarding_wizard", "Pick the look and feel invitees see on your booking page.")}
        </p>
        <div class="grid grid-cols-2 gap-3">
          <button
            :for={{name, id} <- @theme_options}
            type="button"
            phx-click="select_theme"
            phx-value-theme={id}
            aria-pressed={to_string(theme_selected?(@profile, id))}
            class={[
              "p-3 rounded-token-xl border-2 flex flex-col gap-2 transition-colors",
              if(theme_selected?(@profile, id),
                do: "border-turquoise-500 bg-turquoise-50",
                else: "border-tymeslot-200 bg-white hover:border-tymeslot-300"
              )
            ]}
          >
            <PreviewParts.theme_preview
              theme_module={theme_module(id)}
              variant={:thumbnail}
              primary={@primary}
            />
            <span class={[
              "font-semibold text-token-sm",
              if(theme_selected?(@profile, id), do: "text-turquoise-700", else: "text-tymeslot-600")
            ]}>
              {name}
            </span>
          </button>
        </div>
      </div>

      <%!-- Colour scheme --%>
      <div class="onboarding-form-group">
        <label class="label">{dgettext("onboarding_wizard", "Colour scheme")}</label>
        <p class="onboarding-form-helper">
          {dgettext("onboarding_wizard", "Set the accent colour that ties your page together.")}
        </p>
        <div class="flex flex-wrap gap-3">
          <button
            :for={id <- scheme_ids(@color_schemes)}
            type="button"
            phx-click="select_color_scheme"
            phx-value-scheme={id}
            title={get_in(@color_schemes, [id, :name])}
            aria-label={get_in(@color_schemes, [id, :name])}
            class={[
              "w-9 h-9 rounded-full border-2 transition-transform hover:scale-110",
              if(@color_scheme == id,
                do: "border-turquoise-500 ring-2 ring-turquoise-200 scale-110",
                else: "border-white shadow-sm"
              )
            ]}
            style={"background: #{get_in(@color_schemes, [id, :colors, :primary]) || "#14b8a6"};"}
          />
        </div>
      </div>

      <%!-- Real full-page preview --%>
      <div class="onboarding-form-group">
        <button
          type="button"
          phx-click="preview_booking_page"
          class="btn-secondary px-5 py-2.5 inline-flex items-center gap-2 whitespace-nowrap"
        >
          <.icon name="hero-eye-mini" class="w-4 h-4 shrink-0" />
          {dgettext("onboarding_wizard", "Preview booking page")}
        </button>
        <p class="onboarding-form-helper mt-2">
          {dgettext(
            "onboarding_wizard",
            "Opens your real booking page exactly as invitees will see it."
          )}
        </p>
      </div>
    </div>
    """
  end

  defp theme_selected?(profile, id), do: (profile && profile.booking_theme) == id

  defp theme_module(id) do
    ThemeInfo.get_theme_module(id) || ThemeInfo.get_theme_module(Catalog.default_id())
  end

  # Returns colour-scheme ids in a stable display order, appending any
  # ids not present in the canonical list defensively.
  defp scheme_ids(color_schemes) do
    known = Enum.filter(@scheme_order, &Map.has_key?(color_schemes, &1))
    extra = Map.keys(color_schemes) -- known
    known ++ extra
  end
end
