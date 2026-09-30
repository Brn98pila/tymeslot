defmodule Tymeslot.Test.ShowcaseThemeSpec do
  @moduledoc """
  Customisation spec of the test-only showcase theme
  (`test/support/showcase_theme/`, registered by `config/test.exs`): Quill's
  palette and background with the shared logo and cover groups between them, in the
  canonical group order. It exists so that the shared groups no shipped
  theme offers yet are reachable through the real dashboard. The generated
  `changeset/2`, `asset_fields/0` and `tokens/2` stand.
  """
  use Tymeslot.ThemeCustomizations.Spec

  alias Tymeslot.ThemeCustomizations.Options.Background
  alias Tymeslot.ThemeCustomizations.Options.Cover
  alias Tymeslot.ThemeCustomizations.Options.Logo
  alias Tymeslot.ThemeCustomizations.Options.Palette
  alias Tymeslot.ThemeCustomizations.QuillSpec
  alias Tymeslot.ThemeCustomizations.Spec
  alias Tymeslot.ThemeCustomizations.Specs

  @covers ~w(elegant-still-life artistic-studio ocean-sunset rustic-farmhouse)

  @impl Spec
  def option_groups,
    do: [
      Specs.group(QuillSpec, Palette),
      %{key: :logo, module: Logo},
      %{key: :cover, module: Cover, presets: @covers, default: "elegant-still-life"},
      Specs.group(QuillSpec, Background)
    ]

  @impl Spec
  def defaults, do: Map.put(QuillSpec.defaults(), :cover_value, "elegant-still-life")
end
