defmodule Tymeslot.ThemeCustomizations.Options.BackgroundTest do
  use ExUnit.Case, async: true

  @moduletag :themes
  @moduletag :unit

  alias Ecto.Changeset
  alias Tymeslot.ThemeCustomizations.Options.Background
  alias Tymeslot.ThemeCustomizations.ThemeCustomizationSchema

  @all_kinds [:gradient, :color, :image, :video]

  defp changeset(attrs, kinds \\ @all_kinds) do
    %ThemeCustomizationSchema{}
    |> Changeset.change()
    |> Background.changeset(attrs, kinds)
  end

  defp error(cs, field), do: cs.errors |> Keyword.get(field) |> elem(0)

  describe "changeset/3 colour" do
    test "stores a three-digit colour as lower-case #rrggbb" do
      cs = changeset(%{"background_type" => "color", "background_value" => "#FFF"})

      assert cs.valid?
      assert Changeset.get_change(cs, :background_value) == "#ffffff"
    end

    test "rejects the alpha form and non-hex colours" do
      for value <- ["#ff550080", "rgb(255, 0, 0)", "transparent"] do
        cs = changeset(%{"background_type" => "color", "background_value" => value})
        assert error(cs, :background_value) == "must be a valid hex color", value
      end
    end
  end

  describe "changeset/3 kinds" do
    test "rejects a kind the theme does not offer" do
      cs =
        changeset(
          %{"background_type" => "video", "background_value" => "preset:space"},
          [:gradient, :color]
        )

      assert error(cs, :background_type) == "is not supported by this theme"
    end

    test "rejects an unknown kind" do
      assert error(changeset(%{"background_type" => "plaid"}), :background_type) == "is invalid"
    end
  end

  describe "changeset/3 presets and uploads" do
    test "rejects an unknown gradient" do
      cs = changeset(%{"background_type" => "gradient", "background_value" => "gradient_99"})
      assert error(cs, :background_value) == "must be a valid gradient preset"
    end

    test "rejects an unknown image or video preset" do
      image = changeset(%{"background_type" => "image", "background_value" => "preset:nope"})
      video = changeset(%{"background_type" => "video", "background_value" => "preset:nope"})

      assert error(image, :background_value) == "must be a valid image preset"
      assert error(video, :background_value) == "must be a valid video preset"
    end

    test "requires the stored path for an uploaded video" do
      cs = changeset(%{"background_type" => "video", "background_value" => "custom"})
      assert error(cs, :background_video_path) == "is required for uploaded video background"
    end

    test "accepts a known preset without a path" do
      assert changeset(%{
               "background_type" => "image",
               "background_value" => "preset:ocean-sunset"
             }).valid?
    end
  end

  describe "vars/1" do
    test "a gradient sets --theme-background to the preset's CSS" do
      assert Background.vars(%{
               "background_type" => "gradient",
               "background_value" => "gradient_1"
             }) ==
               %{"--theme-background" => "linear-gradient(135deg, #667eea 0%, #764ba2 100%)"}
    end

    test "a colour is emitted normalised" do
      assert Background.vars(%{"background_type" => "color", "background_value" => "#ABCDEF"}) ==
               %{"--theme-background" => "#abcdef"}
    end

    test "an invalid colour emits nothing" do
      assert Background.vars(%{
               "background_type" => "color",
               "background_value" => "</style><script>"
             }) == %{}
    end

    test "an uploaded image is addressed under /uploads with its path sanitised" do
      assert Background.vars(%{
               "background_type" => "image",
               "background_value" => "custom",
               "background_image_path" => "themes/1/1/images/../a b.jpg"
             }) == %{"--theme-background-image" => "url('/uploads/themes/1/1/images/ab.jpg')"}
    end

    test "a video emits no variables" do
      assert Background.vars(%{
               "background_type" => "video",
               "background_value" => "preset:space"
             }) ==
               %{}
    end
  end

  test "asset_fields/0 names both upload columns and their kinds" do
    assert Background.asset_fields() == [
             background_image_path: :image,
             background_video_path: :video
           ]
  end
end
