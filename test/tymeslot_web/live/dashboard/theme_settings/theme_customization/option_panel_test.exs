defmodule TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.OptionPanelTest do
  @moduledoc """
  A dashboard panel offers exactly the presets its option group lists, in the
  group's order, never the whole catalogue.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  @moduletag :themes
  @moduletag :components

  alias Tymeslot.ThemeCustomizations.Options.Background
  alias Tymeslot.ThemeCustomizations.Options.Palette
  alias Tymeslot.ThemeCustomizations.ThemeCustomizationSchema
  alias TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.Components

  @customization %ThemeCustomizationSchema{
    settings: %{
      "color_scheme" => "ocean",
      "background_type" => "gradient",
      "background_value" => "gradient_4"
    }
  }

  @background %{
    key: :background,
    module: Background,
    kinds: [:gradient, :image, :video],
    gradients: ["gradient_4", "gradient_2"],
    images: ["preset:ocean-sunset"],
    videos: ["preset:space"]
  }

  defp render_panel(group, extra \\ []) do
    assigns =
      Keyword.merge(
        [
          group: group,
          customization: @customization,
          uploads: nil,
          myself: nil,
          palette_picker_open: false,
          browsing_type: "gradient",
          custom_picker_open: false
        ],
        extra
      )

    render_component(&Components.option_panel/1, assigns)
  end

  defp choices(html, field) do
    html
    |> Floki.parse_fragment!()
    |> Floki.attribute("button[phx-value-field='#{field}']", "phx-value-choice")
  end

  # A `schemes:` list is the theme's presentation order (onboarding's); the
  # dashboard lists schemes by id, as it always has.
  test "the palette panel shows the group's schemes, sorted by id" do
    html = render_panel(%{key: :palette, module: Palette, schemes: ["ocean", "forest"]})

    assert choices(html, "scheme") == ["forest", "ocean"]
  end

  test "the background panel shows the group's presets of the kind being browsed" do
    assert choices(render_panel(@background), "gradient") == ["gradient_4", "gradient_2"]

    assert choices(render_panel(@background, browsing_type: "image"), "image") ==
             ["preset:ocean-sunset"]

    assert choices(render_panel(@background, browsing_type: "video"), "video") == ["preset:space"]
  end
end
