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

  describe "changes/2" do
    test "sets the kind and value" do
      assert {:ok, %{"background_type" => "color", "background_value" => "#ff5500"}} =
               Background.changes("color", "#ff5500")
    end

    test "a preset of another kind, a gradient or a colour nils both uploads" do
      for {kind, value} <- [
            {"gradient", "gradient_1"},
            {"color", "#ff5500"},
            {"image", "preset:artistic-studio"},
            {"video", "preset:blue-wave"}
          ] do
        assert {:ok, changes} = Background.changes(kind, value)

        assert Map.take(changes, ["background_image_path", "background_video_path"]) ==
                 %{"background_image_path" => nil, "background_video_path" => nil},
               "#{kind}/#{value}"
      end
    end

    test "custom of the same kind keeps its own path and clears the other" do
      assert {:ok, image_changes} = Background.changes("image", "custom")
      refute Map.has_key?(image_changes, "background_image_path")
      assert Map.fetch(image_changes, "background_video_path") == {:ok, nil}

      assert {:ok, video_changes} = Background.changes("video", "custom")
      refute Map.has_key?(video_changes, "background_video_path")
      assert Map.fetch(video_changes, "background_image_path") == {:ok, nil}
    end
  end

  describe "descriptor/1" do
    test "a gradient resolves to the preset's CSS" do
      assert Background.descriptor(%{
               "background_type" => "gradient",
               "background_value" => "gradient_1"
             }) ==
               %{kind: :gradient, css: "linear-gradient(135deg, #667eea 0%, #764ba2 100%)"}
    end

    test "an invalid colour resolves to nothing" do
      assert Background.descriptor(%{
               "background_type" => "color",
               "background_value" => "</style><script>"
             }) == nil
    end

    test "an uploaded image is addressed under /uploads with its path sanitised" do
      assert Background.descriptor(%{
               "background_type" => "image",
               "background_value" => "custom",
               "background_image_path" => "themes/1/1/images/../a b.jpg"
             }) == %{kind: :image, url: "/uploads/themes/1/1/images/ab.jpg"}
    end

    test "an uploaded video keeps every dot of its name in the variant paths" do
      %{kind: :video, sources: sources} =
        Background.descriptor(%{
          "background_type" => "video",
          "background_value" => "custom",
          "background_video_path" => "videos/my.video.file.mp4"
        })

      srcs = Enum.map(sources, & &1.src)

      assert "/uploads/videos/my.video.file-desktop.webm" in srcs
      assert List.last(srcs) == "/uploads/videos/my.video.file.mp4"
    end

    test "an uploaded video path is sanitised before it reaches a source" do
      %{kind: :video, sources: sources} =
        Background.descriptor(%{
          "background_type" => "video",
          "background_value" => "custom",
          "background_video_path" => "videos/<script>alert(1)</script>.mp4"
        })

      assert sources != []

      for %{src: src} <- sources do
        refute src =~ "<"
        refute src =~ "("
      end
    end

    test "an unknown video preset has no sources and no poster" do
      assert Background.descriptor(%{
               "background_type" => "video",
               "background_value" => "preset:nope"
             }) == %{kind: :video, sources: [], poster: nil}
    end
  end

  describe "vars/2" do
    test "a gradient or colour is the --theme-background itself" do
      assert Background.vars(%{kind: :color, color: "#abcdef"}, %{}) ==
               %{"--theme-background" => "#abcdef"}

      assert Background.vars(%{kind: :gradient, css: "linear-gradient(red, blue)"}, %{}) ==
               %{"--theme-background" => "linear-gradient(red, blue)"}
    end

    test "behind a video the palette's canvas shows" do
      video = %{kind: :video, sources: [], poster: nil}

      assert Background.vars(video, %{"--theme-canvas" => "#0f172a"}) ==
               %{"--theme-background" => "var(--theme-canvas)"}
    end

    test "with neither a painted background nor a palette, nothing is emitted" do
      assert Background.vars(nil, %{}) == %{}
    end
  end

  test "asset_fields/0 names both upload columns and their kinds" do
    assert Background.asset_fields() == [
             background_image_path: :image,
             background_video_path: :video
           ]
  end
end
