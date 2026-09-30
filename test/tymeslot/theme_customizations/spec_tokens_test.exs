defmodule Tymeslot.ThemeCustomizations.SpecTokensTest do
  @moduledoc """
  Pins what each theme's `tokens/2` hands the renderer: the palette as
  `--theme-*` custom properties (its background as `--theme-canvas`), the
  background option as `--theme-background` plus a structured descriptor, and
  the per-request primary-colour override with its contrast pairs recomputed.
  """
  use ExUnit.Case, async: true

  @moduletag :themes
  @moduletag :unit

  alias Tymeslot.ThemeCustomizations
  alias Tymeslot.ThemeCustomizations.ThemeCustomizationSchema
  alias Tymeslot.ThemeCustomizations.Tokens
  alias Tymeslot.Utils.Colour
  alias TymeslotWeb.ThemeTestMatrix

  defp settings(attrs) do
    %ThemeCustomizationSchema{
      settings:
        Map.merge(
          %{
            "color_scheme" => "default",
            "background_type" => "gradient",
            "background_value" => "gradient_1"
          },
          Map.new(attrs, fn {key, value} -> {Atom.to_string(key), value} end)
        )
    }
  end

  for theme_id <- ThemeTestMatrix.ids() do
    @theme_id theme_id

    describe "theme #{theme_id}: palette" do
      test "palette colours become --theme-* vars and the palette background becomes --theme-canvas" do
        %Tokens{vars: vars} =
          ThemeCustomizations.tokens(@theme_id, settings(color_scheme: "purple"))

        assert vars["--theme-primary"] == "#8b5cf6"
        assert vars["--theme-canvas"] == "#1e1b4b"
        assert vars["--theme-text-secondary"] == "#c4b5fd"
        assert vars["--theme-surface"] == "rgba(46, 38, 84, 0.5)"
      end

      test "carries the filled-control contrast pairs and leaves the palette's own primary alone" do
        %Tokens{vars: vars} =
          ThemeCustomizations.tokens(@theme_id, settings(color_scheme: "turquoise"))

        for name <- ~w(--theme-on-primary --theme-primary-solid --theme-primary-solid-hover
                       --theme-on-accent --theme-accent-solid) do
          assert is_binary(vars[name]), "missing #{name}"
        end

        # Turquoise's solid variant is nudged for contrast; its primary is not.
        assert vars["--theme-primary"] == "#0284c7"
        refute vars["--theme-primary-solid"] == "#0284c7"
      end

      test "a custom seed replaces the preset" do
        %Tokens{vars: vars} =
          ThemeCustomizations.tokens(@theme_id, settings(custom_palette_seed: "#ff6b35"))

        assert vars["--theme-primary"] == "#ff6b35"
      end

      test "no background-image custom property is emitted" do
        %Tokens{vars: vars} =
          ThemeCustomizations.tokens(
            @theme_id,
            settings(background_type: "image", background_value: "preset:ocean-sunset")
          )

        refute Map.has_key?(vars, "--theme-background-image")
      end

      test "dark_vars stay empty" do
        assert %Tokens{dark_vars: dark_vars} = ThemeCustomizations.tokens(@theme_id, settings([]))
        assert dark_vars == %{}
      end
    end

    describe "theme #{theme_id}: background" do
      test "a gradient is both the --theme-background var and the descriptor" do
        css = "linear-gradient(135deg, #2E3192 0%, #1BFFFF 100%)"

        assert %Tokens{vars: %{"--theme-background" => ^css}, media: %{background: background}} =
                 ThemeCustomizations.tokens(@theme_id, settings(background_value: "gradient_2"))

        assert background == %{kind: :gradient, css: css}
      end

      test "a solid colour is normalised" do
        assert %Tokens{
                 vars: %{"--theme-background" => "#aabbcc"},
                 media: %{background: background}
               } =
                 ThemeCustomizations.tokens(
                   @theme_id,
                   settings(background_type: "color", background_value: "#ABC")
                 )

        assert background == %{kind: :color, color: "#aabbcc"}
      end

      test "a preset image resolves under /images/themes/backgrounds and paints the canvas behind it" do
        assert %Tokens{vars: vars, media: %{background: background}} =
                 ThemeCustomizations.tokens(
                   @theme_id,
                   settings(background_type: "image", background_value: "preset:ocean-sunset")
                 )

        assert background == %{kind: :image, url: "/images/themes/backgrounds/ocean-sunset.webp"}
        assert vars["--theme-background"] == "var(--theme-canvas)"
      end

      test "an uploaded image path is sanitised" do
        assert %Tokens{media: %{background: %{kind: :image, url: url}}} =
                 ThemeCustomizations.tokens(
                   @theme_id,
                   settings(
                     background_type: "image",
                     background_value: "custom",
                     background_image_path: "themes/1/1/images/../../bg.png"
                   )
                 )

        assert url == "/uploads/themes/1/1/images/bg.png"
      end

      test "a preset video lists the five responsive sources and the preset poster" do
        assert %Tokens{media: %{background: %{kind: :video, sources: sources, poster: poster}}} =
                 ThemeCustomizations.tokens(
                   @theme_id,
                   settings(background_type: "video", background_value: "preset:blue-wave")
                 )

        assert poster == "/images/ui/posters/blue-wave-poster.jpg"
        assert length(sources) == 5

        assert hd(sources) == %{
                 src: "/videos/backgrounds/blue-wave-desktop.webm",
                 type: "video/webm",
                 media: "(min-width: 1024px)"
               }

        assert List.last(sources) == %{
                 src: "/videos/backgrounds/blue-wave-original.mp4",
                 type: "video/mp4",
                 media: nil
               }
      end

      test "an uploaded video lists the transcoded variants, then the original, and has no poster" do
        assert %Tokens{media: %{background: %{kind: :video, sources: sources, poster: nil}}} =
                 ThemeCustomizations.tokens(
                   @theme_id,
                   settings(
                     background_type: "video",
                     background_value: "custom",
                     background_video_path: "themes/1/1/videos/clip.mp4"
                   )
                 )

        assert hd(sources).src == "/uploads/themes/1/1/videos/clip-desktop.webm"

        assert List.last(sources) == %{
                 src: "/uploads/themes/1/1/videos/clip.mp4",
                 type: "video/mp4",
                 media: nil
               }
      end

      test "an unknown gradient reads as the theme's default background" do
        assert %Tokens{media: media} =
                 ThemeCustomizations.tokens(@theme_id, settings(background_value: "gradient_999"))

        assert media.background ==
                 ThemeCustomizations.tokens(@theme_id, nil).media.background
      end
    end

    describe "theme #{theme_id}: primary-colour override" do
      test "replaces primary and recomputes hover and the contrast pairs" do
        %Tokens{vars: default} = ThemeCustomizations.tokens(@theme_id, settings([]))

        %Tokens{vars: vars} =
          ThemeCustomizations.tokens(@theme_id, settings([]), %{primary_color: "#e11d48"})

        assert vars["--theme-primary"] == "#e11d48"
        refute vars["--theme-primary-hover"] == default["--theme-primary-hover"]

        assert Colour.relative_luminance(vars["--theme-primary-hover"]) <
                 Colour.relative_luminance("#e11d48")

        refute vars["--theme-primary-solid"] == default["--theme-primary-solid"]

        assert Colour.contrast_ratio(vars["--theme-on-primary"], vars["--theme-primary-solid"]) >=
                 4.5
      end

      test "leaves the rest of the palette alone" do
        %Tokens{vars: default} = ThemeCustomizations.tokens(@theme_id, settings([]))

        %Tokens{vars: vars} =
          ThemeCustomizations.tokens(@theme_id, settings([]), %{primary_color: "#e11d48"})

        assert vars["--theme-canvas"] == default["--theme-canvas"]
        assert vars["--theme-accent"] == default["--theme-accent"]
      end
    end
  end
end
