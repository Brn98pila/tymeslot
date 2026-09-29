defmodule Tymeslot.ThemeCustomizations.Spec do
  @moduledoc """
  The customisation contract every booking theme declares.

  A spec says which option groups a theme offers, what its defaults are, how a
  write is validated and how the stored settings become CSS tokens. It is the
  only place a theme's customisation defaults and rules live: every write
  (dashboard, uploads, onboarding, account provisioning) goes through
  `changeset/2`, and the booking page reads through `tokens/2`.

  Each theme names its spec in its `Tymeslot.Themes.Catalog` entry
  (`customization_spec:`).
  """

  alias Ecto.Changeset
  alias Tymeslot.ThemeCustomizations.Options.Background
  alias Tymeslot.ThemeCustomizations.Options.Palette
  alias Tymeslot.ThemeCustomizations.Tokens
  alias Tymeslot.Themes.Catalog

  @typedoc "A kind of background a theme can show."
  @type background_kind :: :gradient | :color | :image | :video

  @typedoc "Declarative descriptor of one customisation panel."
  @type option_group ::
          %{key: :palette, type: :palette}
          | %{key: :background, type: :background, kinds: [background_kind()]}

  @typedoc "Stored settings with string keys, as `ThemeCustomizations.to_map/1` returns them."
  @type settings :: %{optional(String.t()) => term()}

  @typedoc "Per-page-view overrides, such as an embed's accent colour. Empty when there are none."
  @type overrides :: %{optional(atom()) => term()}

  @typedoc "What an uploaded asset field stores."
  @type asset_kind :: :image | :video

  @doc "The panels the dashboard shows for this theme, in order."
  @callback option_groups() :: [option_group()]

  @doc "The theme's defaults, keyed by setting name. The only place they live."
  @callback defaults() :: %{optional(atom()) => term()}

  @doc """
  Casts and validates the theme's settings. The changeset is a schemaless one
  over `setting_types/1`, holding the stored settings as its data, so the spec
  works with plain `cast/3`, `get_field/2` and `add_error/3`; the schema
  stores the result in its `settings` map. Rejects any option or value the
  theme does not support.
  """
  @callback changeset(Changeset.t(), map()) :: Changeset.t()

  @doc "Resolves stored settings plus per-page-view overrides to CSS tokens."
  @callback tokens(settings(), overrides()) :: Tokens.t()

  @doc "The settings that hold uploaded files, and the kind of each, for upload handling and clean-up."
  @callback asset_fields() :: [{atom(), asset_kind()}]

  @doc """
  The settings a spec stores, with their Ecto types: those of each of its
  option groups. A stored key outside these is dropped on the next save.
  """
  @spec setting_types(module()) :: %{atom() => atom()}
  def setting_types(spec) do
    spec.option_groups()
    |> Enum.map(fn
      %{type: :palette} -> Palette.types()
      %{type: :background} -> Background.types()
    end)
    |> Enum.reduce(%{}, &Map.merge/2)
  end

  @doc "The background kinds a spec declares; empty when it has no background group."
  @spec background_kinds(module()) :: [background_kind()]
  def background_kinds(spec) do
    Enum.find_value(spec.option_groups(), [], fn
      %{type: :background, kinds: kinds} -> kinds
      _other_group -> nil
    end)
  end

  @doc "Whether a spec offers the given background kind."
  @spec supports_background?(module(), background_kind()) :: boolean()
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
