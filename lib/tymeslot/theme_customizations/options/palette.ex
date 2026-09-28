defmodule Tymeslot.ThemeCustomizations.Options.Palette do
  @moduledoc """
  The colour-palette option: a preset scheme, or a palette derived from a
  custom seed colour. Stored in the `color_scheme` and `custom_palette_seed`
  columns; a present seed is the source of truth and the scheme name is then
  left unconstrained.
  """

  import Ecto.Changeset

  alias Ecto.Changeset
  alias Tymeslot.ThemeCustomizations.ContrastTokens
  alias Tymeslot.ThemeCustomizations.PaletteDerivation
  alias Tymeslot.ThemeCustomizations.Presets
  alias Tymeslot.ThemeCustomizations.Spec
  alias Tymeslot.ThemeCustomizations.Tokens
  alias Tymeslot.Utils.Colour

  @fields [:color_scheme, :custom_palette_seed]

  @doc "Casts and validates the palette settings."
  @spec changeset(Changeset.t(), map()) :: Changeset.t()
  def changeset(changeset, attrs) do
    changeset
    |> cast(attrs, @fields)
    |> cast_seed()
    |> validate_scheme_unless_seeded()
  end

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
  The palette's CSS variables, including the contrast pairs filled controls
  need. Empty when no scheme is stored.
  """
  @spec vars(Spec.settings()) :: Tokens.css_vars()
  def vars(%{"color_scheme" => scheme} = settings) when is_binary(scheme) do
    case resolve(settings) do
      %{colors: colors} -> colours_to_vars(colors)
      nil -> %{}
    end
  end

  def vars(_settings), do: %{}

  @doc "Turns a palette's `colors` map into `--theme-*` variables plus its contrast tokens."
  @spec colours_to_vars(map()) :: Tokens.css_vars()
  def colours_to_vars(colors) do
    colors
    |> Map.merge(ContrastTokens.derive(colors) || %{})
    |> Map.new(fn {key, value} ->
      {"--theme-" <> String.replace(to_string(key), "_", "-"), value}
    end)
  end

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
