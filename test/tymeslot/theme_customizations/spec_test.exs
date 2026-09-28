defmodule Tymeslot.ThemeCustomizations.SpecTest do
  use ExUnit.Case, async: true

  @moduletag :themes
  @moduletag :unit

  alias Ecto.Changeset
  alias Tymeslot.ThemeCustomizations.QuillSpec
  alias Tymeslot.ThemeCustomizations.RhythmSpec
  alias Tymeslot.ThemeCustomizations.Spec
  alias Tymeslot.ThemeCustomizations.ThemeCustomizationSchema
  alias Tymeslot.ThemeCustomizations.Tokens

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
    %ThemeCustomizationSchema{} |> Changeset.change() |> spec.changeset(attrs)
  end

  describe "Spec.supports_background?/2" do
    test "is false for a kind the spec does not declare" do
      refute Spec.supports_background?(StillSpec, :video)
      assert Spec.supports_background?(StillSpec, :gradient)
    end

    test "Quill and Rhythm offer every background kind" do
      assert Spec.background_kinds(QuillSpec) == [:gradient, :color, :image, :video]
      assert Spec.background_kinds(RhythmSpec) == [:gradient, :color, :image, :video]
    end
  end

  describe "defaults/0" do
    test "Quill defaults to the Aurora gradient, Rhythm to its own video" do
      assert %{background_type: "gradient", background_value: "gradient_1"} = QuillSpec.defaults()

      assert %{background_type: "video", background_value: "preset:rhythm-default"} =
               RhythmSpec.defaults()
    end

    test "each theme's defaults pass its own changeset" do
      assert validate(QuillSpec, stringify(QuillSpec.defaults())).valid?
      assert validate(RhythmSpec, stringify(RhythmSpec.defaults())).valid?
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
