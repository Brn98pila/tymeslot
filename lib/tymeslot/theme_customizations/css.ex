defmodule Tymeslot.ThemeCustomizations.Css do
  @moduledoc """
  Pure palette lookups for theme customizations.

  Stateless functions over the presets and palette derivation: the active
  colour scheme of a customisation. The booking page's CSS comes from the
  theme's customisation spec (`Tymeslot.ThemeCustomizations.Spec.tokens/2`),
  not from here. No database access and no filesystem side effects live here.
  """

  alias Tymeslot.ThemeCustomizations.DataTransform
  alias Tymeslot.ThemeCustomizations.PaletteDerivation
  alias Tymeslot.ThemeCustomizations.ThemeCustomizationSchema

  @doc """
  Resolves the active colour scheme for a customisation, returning the same
  `%{name, colors}` shape used by both presets and palette derivation.

  When `custom_palette_seed` is present on the customisation, the palette is
  derived from that seed; otherwise the `color_scheme` field is looked up in
  the provided `presets.color_schemes` map. Returns `nil` if neither resolves
  to a known scheme.
  """
  @spec resolve_active_scheme(ThemeCustomizationSchema.t() | map(), map()) :: map() | nil
  def resolve_active_scheme(customization, presets) do
    case DataTransform.to_settings(customization) do
      %{"custom_palette_seed" => seed} when is_binary(seed) and seed != "" ->
        PaletteDerivation.derive_palette(seed)

      settings ->
        Map.get(presets.color_schemes, settings["color_scheme"])
    end
  end
end
