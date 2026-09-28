defmodule Tymeslot.ThemeCustomizations.Css do
  @moduledoc """
  Pure CSS and palette resolution for theme customizations.

  Stateless functions that turn a colour scheme, gradient preset, or full
  customisation into the CSS variable strings consumed by the booking themes.
  A full customisation's page CSS is resolved through the theme's customisation
  spec (`Tymeslot.ThemeCustomizations.Spec`), named in its Catalog entry.
  No database access and no filesystem side effects live here — palette
  derivation is delegated to `PaletteDerivation` and preset lookups to
  `Presets`, mirroring how the context orchestrated these calls previously.
  """

  alias Tymeslot.ThemeCustomizations.DataTransform
  alias Tymeslot.ThemeCustomizations.Options.Palette
  alias Tymeslot.ThemeCustomizations.PaletteDerivation
  alias Tymeslot.ThemeCustomizations.Presets
  alias Tymeslot.ThemeCustomizations.Spec
  alias Tymeslot.ThemeCustomizations.ThemeCustomizationSchema
  alias Tymeslot.ThemeCustomizations.Validation
  alias Tymeslot.Themes.Catalog

  @doc """
  Gets the CSS variables for a colour scheme.

  Accepts either a scheme ID (string/atom — looked up in the static preset map)
  or a customisation map. The map form supports the "custom" scheme: when
  `color_scheme == "custom"`, the palette is derived from `custom_palette_seed`
  via `PaletteDerivation.derive_palette/1` instead of preset lookup.
  """
  @spec get_color_scheme_css(String.t() | atom() | map()) :: String.t() | nil
  def get_color_scheme_css(customization) when is_map(customization) do
    case customization |> DataTransform.convert_to_map() |> Palette.resolve() do
      %{colors: colors} -> colors |> Palette.colours_to_vars() |> render_vars()
      nil -> nil
    end
  end

  def get_color_scheme_css(scheme_id) when is_binary(scheme_id) or is_atom(scheme_id) do
    case Presets.find_preset_by_id(:color_scheme, scheme_id) do
      %{colors: colors} -> colors |> Palette.colours_to_vars() |> render_vars()
      nil -> nil
    end
  end

  @doc """
  Gets the CSS for a gradient preset.
  """
  @spec get_gradient_css(String.t() | atom()) :: String.t() | nil
  def get_gradient_css(gradient_id) do
    case Presets.find_preset_by_id(:gradient, gradient_id) do
      nil -> nil
      %{value: value} -> value
    end
  end

  @doc """
  The page's CSS variables for a theme and its stored settings, resolved
  through the theme's customisation spec. Empty for an unknown theme.
  """
  @spec generate_theme_css(String.t(), Spec.settings()) :: String.t()
  def generate_theme_css(theme_id, settings) do
    case Catalog.customization_spec(theme_id) do
      {:ok, spec} ->
        settings
        |> spec.tokens(%{})
        |> Map.fetch!(:vars)
        |> render_vars()
        |> Validation.sanitize_css()

      {:error, :theme_not_found} ->
        ""
    end
  end

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

  @doc """
  Extracts the custom palette seed from a customisation schema or map.
  """
  @spec get_seed(ThemeCustomizationSchema.t() | map()) :: String.t() | nil
  def get_seed(%ThemeCustomizationSchema{custom_palette_seed: seed}), do: seed

  def get_seed(map) when is_map(map) do
    Map.get(map, :custom_palette_seed) || Map.get(map, "custom_palette_seed")
  end

  @spec get_scheme_id(ThemeCustomizationSchema.t() | map()) :: String.t() | nil
  defp get_scheme_id(%ThemeCustomizationSchema{color_scheme: s}), do: s

  defp get_scheme_id(map) when is_map(map) do
    Map.get(map, :color_scheme) || Map.get(map, "color_scheme")
  end

  # --- Private helpers ----------------------------------------------------

  defp render_vars(vars),
    do: Enum.map_join(vars, "\n", fn {name, value} -> "#{name}: #{value};" end)
end
