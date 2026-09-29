defmodule Tymeslot.ThemeCustomizations.SpecsTest do
  use ExUnit.Case, async: true

  @moduletag :themes
  @moduletag :unit

  alias Tymeslot.ThemeCustomizations.Options.Background
  alias Tymeslot.ThemeCustomizations.QuillSpec
  alias Tymeslot.ThemeCustomizations.Specs
  alias Tymeslot.Themes.Catalog

  @known_kinds [:gradient, :color, :image, :video]

  # An option group no shipped theme has: shared code must handle it through
  # its module alone.
  defmodule TaglineOption do
    @moduledoc false
    @behaviour Tymeslot.ThemeCustomizations.OptionGroup

    import Ecto.Changeset

    @impl Tymeslot.ThemeCustomizations.OptionGroup
    def types, do: %{tagline: :string}

    @impl Tymeslot.ThemeCustomizations.OptionGroup
    def changeset(changeset, attrs, group),
      do: changeset |> cast(attrs, [:tagline]) |> validate_length(:tagline, max: group.max)

    @impl Tymeslot.ThemeCustomizations.OptionGroup
    def changes("text", value, _group), do: {:ok, %{"tagline" => value}}
    def changes(_field, _value, _group), do: :error
  end

  # A theme that offers no video, like the minimalist theme will, and an
  # option group of its own.
  defmodule StillSpec do
    @moduledoc false
    use Tymeslot.ThemeCustomizations.Spec

    alias Tymeslot.ThemeCustomizations.Options.Background
    alias Tymeslot.ThemeCustomizations.SpecsTest.TaglineOption
    alias Tymeslot.ThemeCustomizations.Tokens

    @impl Tymeslot.ThemeCustomizations.Spec
    def option_groups,
      do: [
        %{
          key: :background,
          module: Background,
          kinds: [:gradient, :color, :image],
          gradients: ["gradient_1"],
          images: ["preset:ocean-sunset"]
        },
        %{key: :tagline, module: TaglineOption, max: 10}
      ]

    @impl Tymeslot.ThemeCustomizations.Spec
    def defaults, do: %{background_type: "gradient", background_value: "gradient_1"}

    @impl Tymeslot.ThemeCustomizations.Spec
    def tokens(_settings, _overrides), do: %Tokens{}
  end

  describe "setting_types/1" do
    test "merges every group module's types" do
      assert Specs.setting_types(StillSpec) == Map.put(Background.types(), :tagline, :string)
    end
  end

  describe "group/2" do
    test "finds a spec's group by its module" do
      assert %{key: :tagline, max: 10} = Specs.group(StillSpec, TaglineOption)
      assert Specs.group(QuillSpec, TaglineOption) == nil
    end
  end

  describe "for_theme/1" do
    for {_key, theme} <- Catalog.all() do
      test "returns #{theme.name}'s spec" do
        assert Specs.for_theme(unquote(theme.id)) == unquote(theme.customization_spec)
      end
    end

    test "falls back to the default theme's spec for an unknown id" do
      assert Specs.for_theme("no-such-theme") == Catalog.default().customization_spec
    end
  end

  describe "supports_background?/2" do
    test "is false for a kind the spec does not declare" do
      refute Specs.supports_background?(StillSpec, :video)
      assert Specs.supports_background?(StillSpec, :gradient)
    end

    # Every catalogue theme, so a new one is checked the moment it is listed.
    for {_key, theme} <- Catalog.all() do
      test "#{theme.name} declares only known background kinds, each once" do
        kinds = Specs.background_kinds(unquote(theme.customization_spec))

        assert kinds == Enum.uniq(kinds)
        assert kinds -- @known_kinds == []
      end
    end
  end
end
