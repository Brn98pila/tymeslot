defmodule Tymeslot.ThemeCustomizations.Specs do
  @moduledoc """
  Questions asked of a theme's customisation spec: its option groups, the settings they store, the background kinds it offers, the media and tokens its groups resolve, and the spec for a theme id. Kept apart from `Spec`, which a spec `use`s at compile time and must therefore depend on nothing.
  """

  alias Tymeslot.ThemeCustomizations.OptionGroup
  alias Tymeslot.ThemeCustomizations.Options.Background
  alias Tymeslot.ThemeCustomizations.Options.Palette
  alias Tymeslot.ThemeCustomizations.Spec
  alias Tymeslot.ThemeCustomizations.Tokens
  alias Tymeslot.Themes.Catalog

  @doc """
  The settings a spec stores, with their Ecto types: those of each of its
  option groups' modules. A stored key outside these is dropped on the next
  save.
  """
  @spec setting_types(module()) :: %{atom() => atom()}
  def setting_types(spec) do
    spec.option_groups()
    |> Enum.map(& &1.module.types())
    |> Enum.reduce(%{}, &Map.merge/2)
  end

  @doc """
  The render-ready media a spec's option groups resolve from the stored
  settings: every group's `media/2`, merged in declaration order. A group
  without `media/2` contributes nothing, and a key whose value is `nil` is left
  out, so `media[:logo]` is `nil` exactly when there is no logo to render.
  """
  @spec media(module(), Spec.settings()) :: Tokens.media()
  def media(spec, settings) do
    spec.option_groups()
    |> Enum.reduce(%{}, fn group, acc -> Map.merge(acc, OptionGroup.media(settings, group)) end)
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  @doc """
  The standard tokens for a spec's stored settings and page-view overrides,
  the default `tokens/2` that `use Spec` generates: the palette group's
  variables (`Options.Palette.tokens/3`), with the background group's
  `--theme-background` merged over them; the palette's dark variables; and
  every group's media (`media/2`). A spec without a palette group has no
  palette variables, and one without a background group no background
  variable. A spec with tokens of its own overrides `tokens/2` and starts
  from this.
  """
  @spec tokens(module(), Spec.settings(), Spec.overrides()) :: Tokens.t()
  def tokens(spec, settings, overrides) do
    palette = palette_tokens(group(spec, Palette), settings, overrides)
    media = media(spec, settings)

    %Tokens{
      vars: Map.merge(palette.vars, background_vars(spec, media, palette.vars)),
      dark_vars: palette.dark_vars,
      media: media
    }
  end

  @doc "The spec's first option group implemented by `module`, or `nil`."
  @spec group(module(), module()) :: OptionGroup.group() | nil
  def group(spec, module), do: Enum.find(spec.option_groups(), &(&1.module == module))

  @doc "The background kinds a spec declares; empty when it has no background group."
  @spec background_kinds(module()) :: [Spec.background_kind()]
  def background_kinds(spec) do
    case group(spec, Background) do
      %{kinds: kinds} -> kinds
      nil -> []
    end
  end

  @doc "Whether a spec offers the given background kind."
  @spec supports_background?(module(), Spec.background_kind()) :: boolean()
  def supports_background?(spec, kind), do: kind in background_kinds(spec)

  @doc "The spec for a theme id, falling back to the default theme's spec for an unknown id."
  @spec for_theme(String.t()) :: module()
  def for_theme(theme_id) do
    case Catalog.customization_spec(theme_id) do
      {:ok, spec} -> spec
      {:error, :theme_not_found} -> Catalog.default().customization_spec
    end
  end

  defp palette_tokens(nil, _settings, _overrides), do: %{vars: %{}, dark_vars: %{}}
  defp palette_tokens(group, settings, overrides), do: Palette.tokens(settings, overrides, group)

  defp background_vars(spec, media, palette_vars) do
    case group(spec, Background) do
      nil -> %{}
      _group -> Background.vars(media[:background], palette_vars)
    end
  end
end
