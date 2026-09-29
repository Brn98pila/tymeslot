defmodule Tymeslot.ThemeCustomizations.Options.Palette do
  @moduledoc """
  The colour-palette option: a preset scheme, or a palette derived from a
  custom seed colour. Stored as the `color_scheme` and `custom_palette_seed`
  settings; a present seed is the source of truth and the scheme name is then
  left unconstrained.

  An `OptionGroup`: a spec lists it as `%{key: :palette, module: Options.Palette}`.
  """

  import Ecto.Changeset

  alias Tymeslot.ThemeCustomizations.ContrastTokens
  alias Tymeslot.ThemeCustomizations.OptionGroup
  alias Tymeslot.ThemeCustomizations.PaletteDerivation
  alias Tymeslot.ThemeCustomizations.Presets
  alias Tymeslot.ThemeCustomizations.Spec
  alias Tymeslot.ThemeCustomizations.Tokens
  alias Tymeslot.Utils.Colour

  @behaviour OptionGroup

  @types %{color_scheme: :string, custom_palette_seed: :string}
  @fields Map.keys(@types)

  # Palette key -> custom property. The palette's `background` is the page's
  # base colour, `--theme-canvas`; `--theme-background` belongs to the
  # background option.
  @var_names %{
    primary: "--theme-primary",
    primary_hover: "--theme-primary-hover",
    secondary: "--theme-secondary",
    accent: "--theme-accent",
    background: "--theme-canvas",
    surface: "--theme-surface",
    text: "--theme-text",
    text_secondary: "--theme-text-secondary",
    on_primary: "--theme-on-primary",
    primary_solid: "--theme-primary-solid",
    primary_solid_hover: "--theme-primary-solid-hover",
    on_accent: "--theme-on-accent",
    accent_solid: "--theme-accent-solid"
  }

  @typedoc "Per-request overrides a single page view may apply on top of the saved palette."
  @type overrides :: %{optional(:primary_color) => String.t()}

  @doc "The settings the palette stores, with their Ecto types."
  @impl OptionGroup
  def types, do: @types

  @doc "Casts and validates the palette settings."
  @impl OptionGroup
  def changeset(changeset, attrs, _group) do
    changeset
    |> cast(attrs, @fields)
    |> cast_seed()
    |> validate_scheme_unless_seeded()
  end

  @doc """
  The changes one palette choice makes, or `:error` for a field the palette
  does not have. Choosing a scheme drops the custom seed.
  """
  @impl OptionGroup
  def changes("scheme", scheme, _group),
    do: {:ok, %{"color_scheme" => scheme, "custom_palette_seed" => nil}}

  def changes("seed", hex, _group), do: {:ok, %{"custom_palette_seed" => hex}}
  def changes(_field, _value, _group), do: :error

  @doc """
  The active palette (`%{name: _, colors: _}`): derived from the seed when one
  is stored, otherwise the named preset. `nil` when neither resolves.
  """
  @spec resolve(Spec.settings()) :: map() | nil
  def resolve(%{"custom_palette_seed" => seed}) when is_binary(seed) and seed != "",
    do: PaletteDerivation.derive_palette(seed)

  def resolve(%{"color_scheme" => scheme}) when is_binary(scheme),
    do: Presets.find_preset_by_id(:color_scheme, scheme)

  def resolve(_settings), do: nil

  @doc """
  The palette as CSS custom properties: the eight palette colours plus the
  contrast pairs `ContrastTokens` derives from them.

  A `:primary_color` override replaces the primary (and its hover shade)
  before the contrast pairs are derived, so filled controls stay legible on
  the override. Empty when no scheme is stored or the stored palette does not
  resolve.
  """
  @spec vars(Spec.settings(), overrides()) :: Tokens.css_vars()
  def vars(%{"color_scheme" => scheme} = settings, overrides)
      when is_binary(scheme) and is_map(overrides) do
    case resolve(settings) do
      %{colors: colors} -> colors |> override_primary(overrides) |> colours_to_vars()
      nil -> %{}
    end
  end

  def vars(_settings, _overrides), do: %{}

  # A palette's `colors` map as `--theme-*` variables plus its contrast
  # tokens; the palette's `background` becomes `--theme-canvas`.
  defp colours_to_vars(colors) do
    colors
    |> Map.merge(ContrastTokens.derive(colors) || %{})
    |> Enum.flat_map(fn {key, value} ->
      case Map.fetch(@var_names, key) do
        {:ok, name} -> [{name, value}]
        :error -> []
      end
    end)
    |> Map.new()
  end

  defp override_primary(colors, %{primary_color: hex}) when is_binary(hex),
    do: %{colors | primary: hex, primary_hover: PaletteDerivation.hover_for(hex) || hex}

  defp override_primary(colors, _overrides), do: colors

  defp cast_seed(changeset) do
    case get_change(changeset, :custom_palette_seed) do
      nil ->
        changeset

      seed ->
        case Colour.cast_hex(seed) do
          {:ok, hex} -> put_change(changeset, :custom_palette_seed, hex)
          :error -> add_error(changeset, :custom_palette_seed, "must be a valid hex colour")
        end
    end
  end

  defp validate_scheme_unless_seeded(changeset) do
    if get_field(changeset, :custom_palette_seed) do
      changeset
    else
      changeset
      |> validate_required([:color_scheme])
      |> validate_inclusion(:color_scheme, Map.keys(Presets.get_color_schemes()))
    end
  end
end
