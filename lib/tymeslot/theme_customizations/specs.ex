defmodule Tymeslot.ThemeCustomizations.Specs do
  @moduledoc """
  Questions asked of a theme's customisation spec: its option groups, the settings they store, the background kinds it offers, the media and tokens its groups resolve, the group an upload belongs to, and the spec for a theme id. Kept apart from `Spec`, which a spec `use`s at compile time and must therefore depend on nothing.
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
  the default `tokens/2` that `use Spec` generates: every group's `tokens/4`
  (`OptionGroup.tokens/4`), folded in declaration order from empty `vars` and
  `dark_vars`, so each group receives what the groups before it produced;
  then every group's media (`media/2`). The palette puts in its colours and
  contrast pairs, a background group after it `--theme-background`, and a
  group without `tokens/4` changes nothing. A spec with tokens of its own
  overrides `tokens/2` and starts from this.
  """
  @spec tokens(module(), Spec.settings(), Spec.overrides()) :: Tokens.t()
  def tokens(spec, settings, overrides) do
    %{vars: vars, dark_vars: dark_vars} =
      Enum.reduce(spec.option_groups(), %{vars: %{}, dark_vars: %{}}, fn group, acc ->
        OptionGroup.tokens(settings, overrides, acc, group)
      end)

    %Tokens{vars: vars, dark_vars: dark_vars, media: media(spec, settings)}
  end

  @doc """
  The option group that takes uploads into the asset field `field`, with the
  field's kind. `:error` when no group of the spec declares the field in its
  `asset_fields/1`, or when the group that does has no `upload_changes/3`.
  """
  @spec upload_group(module(), atom()) ::
          {:ok, OptionGroup.group(), Spec.asset_kind()} | :error
  def upload_group(spec, field) do
    Enum.find_value(spec.option_groups(), :error, fn group ->
      with true <- OptionGroup.uploads?(group),
           {^field, kind} <- List.keyfind(OptionGroup.asset_fields(group), field, 0) do
        {:ok, group, kind}
      else
        _other -> nil
      end
    end)
  end

  @doc """
  The settings an upload stored at `path` writes into `group`'s asset field
  `field`: the group's `upload_changes/3`, keeping only the group's own
  settings (its `types/0`), so an upload never changes another group's
  options or clears another group's files. Keys are strings, as saves take them.
  """
  @spec upload_changes(OptionGroup.group(), atom(), String.t()) :: map()
  def upload_changes(%{module: module} = group, field, path) do
    own = Enum.map(module.types(), fn {key, _type} -> Atom.to_string(key) end)

    field
    |> module.upload_changes(path, group)
    |> Map.take(own)
  end

  @doc "The spec's first option group implemented by `module`, or `nil`."
  @spec group(module(), module()) :: OptionGroup.group() | nil
  def group(spec, module), do: Enum.find(spec.option_groups(), &(&1.module == module))

  @doc """
  The onboarding choices of a spec's palette group, or `nil` when it has none:
  the default `onboarding_choices/0` that `use Spec` generates.
  """
  @spec palette_choices(module()) :: Spec.onboarding_choices()
  def palette_choices(spec) do
    case group(spec, Palette) do
      nil -> nil
      palette -> Palette.onboarding_choices(palette)
    end
  end

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
end
