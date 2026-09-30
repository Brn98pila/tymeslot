defmodule TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.Panels do
  @moduledoc """
  Which dashboard panel renders an option group.

  The theme's own panels come first (`use TymeslotWeb.Themes.Core.Theme,
  option_panels: %{MyGroup => MyPanel}`), then the built-in panels for the
  shared groups. A group with neither raises, naming its module, so a spec
  that gains a group without a panel fails `panels_test.exs` rather than
  showing nothing.
  """

  alias Tymeslot.ThemeCustomizations.OptionGroup
  alias Tymeslot.ThemeCustomizations.Options.Background
  alias Tymeslot.ThemeCustomizations.Options.Logo
  alias Tymeslot.ThemeCustomizations.Options.Palette
  alias TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.BackgroundPanel
  alias TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.LogoPanel
  alias TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.PalettePanel
  alias TymeslotWeb.Themes.Core.Loader

  @built_in %{Palette => PalettePanel, Background => BackgroundPanel, Logo => LogoPanel}

  @doc "The panel module for `group` in the theme `theme_id`."
  @spec for_group(String.t(), OptionGroup.group()) :: module()
  def for_group(theme_id, %{module: group_module}) do
    case Map.fetch(Map.merge(@built_in, theme_panels(theme_id)), group_module) do
      {:ok, panel} ->
        panel

      :error ->
        raise ArgumentError,
              "no dashboard panel for the option group #{inspect(group_module)} of theme " <>
                "#{inspect(theme_id)}; declare one with `use TymeslotWeb.Themes.Core.Theme, " <>
                "option_panels: %{#{inspect(group_module)} => MyPanel}`"
    end
  end

  defp theme_panels(theme_id) do
    case Loader.load_theme(theme_id) do
      {:ok, theme} -> theme.option_panels()
      {:error, _reason} -> %{}
    end
  end
end
