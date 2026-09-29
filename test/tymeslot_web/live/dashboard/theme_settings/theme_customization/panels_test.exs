defmodule TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.PanelsTest do
  use ExUnit.Case, async: true

  @moduletag :themes
  @moduletag :unit

  alias Tymeslot.ThemeCustomizations.Options.Background
  alias Tymeslot.ThemeCustomizations.Options.Palette
  alias Tymeslot.ThemeCustomizations.Spec
  alias Tymeslot.Themes.Catalog
  alias TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.BackgroundPanel
  alias TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.PalettePanel
  alias TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.Panels

  test "the shared groups get the built-in panels" do
    assert Panels.for_group("1", %{key: :palette, module: Palette}) == PalettePanel
    assert Panels.for_group("1", %{key: :background, module: Background}) == BackgroundPanel
  end

  test "a group without a panel raises, naming the group's module" do
    assert_raise ArgumentError, ~r/Some\.UnknownGroup/, fn ->
      Panels.for_group("1", %{key: :mystery, module: Some.UnknownGroup})
    end
  end

  # Every catalogue theme, so a spec that gains a group without a panel fails
  # here rather than on the organiser's first visit to the dashboard.
  for {_key, theme} <- Catalog.all() do
    test "#{theme.name}: every option group has a panel with render/1" do
      panels =
        Enum.map(
          Spec.for_theme(unquote(theme.id)).option_groups(),
          &Panels.for_group(unquote(theme.id), &1)
        )

      assert panels != []

      assert Enum.reject(
               panels,
               &(Code.ensure_loaded?(&1) and function_exported?(&1, :render, 1))
             ) == []
    end
  end
end
