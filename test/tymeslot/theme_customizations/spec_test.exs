defmodule Tymeslot.ThemeCustomizations.SpecTest do
  use ExUnit.Case, async: true

  @moduletag :themes
  @moduletag :unit

  alias Ecto.Changeset
  alias Tymeslot.ThemeCustomizations.QuillSpec
  alias Tymeslot.ThemeCustomizations.RhythmSpec
  alias Tymeslot.ThemeCustomizations.Spec
  alias Tymeslot.ThemeCustomizations.Tokens
  alias Tymeslot.Themes.Catalog

  @known_kinds [:gradient, :color, :image, :video]

  # A theme that offers no video, like the minimalist theme will.
  defmodule StillSpec do
    @behaviour Tymeslot.ThemeCustomizations.Spec

    @impl Tymeslot.ThemeCustomizations.Spec
    def option_groups, do: [%{key: :background, type: :background, kinds: [:gradient, :color]}]
    @impl Tymeslot.ThemeCustomizations.Spec
    def defaults, do: %{}
    @impl Tymeslot.ThemeCustomizations.Spec
    def changeset(changeset, _attrs), do: changeset
    @impl Tymeslot.ThemeCustomizations.Spec
    def tokens(_settings, _overrides), do: %Tokens{}
    @impl Tymeslot.ThemeCustomizations.Spec
    def asset_fields, do: []
  end

  defp stringify(map), do: Map.new(map, fn {k, v} -> {Atom.to_string(k), v} end)

  defp validate(spec, attrs) do
    {%{}, Spec.setting_types(spec)} |> Changeset.change() |> spec.changeset(attrs)
  end

  describe "Spec.supports_background?/2" do
    test "is false for a kind the spec does not declare" do
      refute Spec.supports_background?(StillSpec, :video)
      assert Spec.supports_background?(StillSpec, :gradient)
    end

    # Every catalogue theme, so a new one is checked the moment it is listed.
    for {_key, theme} <- Catalog.all() do
      test "#{theme.name} declares only known background kinds, each once" do
        kinds = Spec.background_kinds(unquote(theme.customization_spec))

        assert kinds == Enum.uniq(kinds)
        assert kinds -- @known_kinds == []
      end
    end
  end

  describe "defaults/0" do
    for {_key, theme} <- Catalog.all() do
      test "#{theme.name}'s default background is a kind it declares" do
        {:ok, spec} = Catalog.customization_spec(unquote(theme.id))

        case spec.defaults() do
          %{background_type: type} ->
            assert String.to_existing_atom(type) in Spec.background_kinds(spec)

          _no_background_default ->
            assert Spec.background_kinds(spec) == []
        end
      end

      test "#{theme.name}'s defaults pass its own changeset" do
        {:ok, spec} = Catalog.customization_spec(unquote(theme.id))

        assert validate(spec, stringify(spec.defaults())).valid?
      end
    end

    # A product decision per theme, pinned as such: Rhythm's identity is its
    # video, Quill's its gradient.
    test "Quill defaults to the Aurora gradient, Rhythm to its own video" do
      assert %{background_type: "gradient", background_value: "gradient_1"} = QuillSpec.defaults()

      assert %{background_type: "video", background_value: "preset:rhythm-default"} =
               RhythmSpec.defaults()
    end
  end

  describe "tokens/2" do
    test "merges the palette and background variables, the background winning" do
      tokens =
        QuillSpec.tokens(
          %{
            "color_scheme" => "default",
            "background_type" => "color",
            "background_value" => "#123456"
          },
          %{}
        )

      assert tokens.vars["--theme-primary"] == "#06b6d4"
      assert tokens.vars["--theme-background"] == "#123456"
      assert tokens.dark_vars == %{}
    end
  end

  test "asset_fields/0 names the two upload columns" do
    assert QuillSpec.asset_fields() == [
             background_image_path: :image,
             background_video_path: :video
           ]

    assert RhythmSpec.asset_fields() == QuillSpec.asset_fields()
  end
end
