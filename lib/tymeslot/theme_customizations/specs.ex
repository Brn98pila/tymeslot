defmodule Tymeslot.ThemeCustomizations.Specs do
  @moduledoc """
  Questions asked of a theme's customisation spec: its option groups, the settings they store, the background kinds it offers, and the spec for a theme id. Kept apart from `Spec`, which a spec `use`s at compile time and must therefore depend on nothing.
  """

  alias Tymeslot.ThemeCustomizations.OptionGroup
  alias Tymeslot.ThemeCustomizations.Options.Background
  alias Tymeslot.ThemeCustomizations.Spec
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
end
