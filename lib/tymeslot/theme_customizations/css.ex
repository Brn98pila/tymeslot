defmodule Tymeslot.ThemeCustomizations.Css do
  @moduledoc """
  Pure palette lookups for theme customizations.

  Stateless functions over the presets and palette derivation: the active
  colour scheme of a customisation. The booking page's CSS comes from the
  theme's customisation spec (`Tymeslot.ThemeCustomizations.Spec.tokens/2`),
  not from here. No database access and no filesystem side effects live here.
  """

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
    seed = get_seed(customization)

    if is_binary(seed) and seed != "" do
      PaletteDerivation.derive_palette(seed)
    else
      scheme_id = get_scheme_id(customization)
      Map.get(presets.color_schemes, scheme_id)
    end
  end

  @spec get_seed(ThemeCustomizationSchema.t() | map()) :: String.t() | nil
  defp get_seed(%ThemeCustomizationSchema{custom_palette_seed: seed}), do: seed

  defp get_seed(map) when is_map(map) do
    Map.get(map, :custom_palette_seed) || Map.get(map, "custom_palette_seed")
  end

  @spec get_scheme_id(ThemeCustomizationSchema.t() | map()) :: String.t() | nil
  defp get_scheme_id(%ThemeCustomizationSchema{color_scheme: s}), do: s

  defp get_scheme_id(map) when is_map(map) do
    Map.get(map, :color_scheme) || Map.get(map, "color_scheme")
  end
end
