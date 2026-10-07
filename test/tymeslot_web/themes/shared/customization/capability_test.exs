defmodule TymeslotWeb.Themes.Shared.Customization.CapabilityTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :utils

  alias TymeslotWeb.Themes.Shared.Customization.Capability

  test "delegates to Tymeslot.ThemeCustomizations.Capability" do
    assert Capability.get_capability_defaults("1") == %{
             "background_type" => "gradient",
             "background_value" => "gradient_1",
             "color_scheme" => "default"
           }

    # An empty customisation map carries no overrides, so no CSS is emitted.
    assert Capability.generate_css("1", %{}) == ""
  end
end
