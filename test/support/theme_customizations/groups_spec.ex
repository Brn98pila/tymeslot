defmodule Tymeslot.Test.ThemeCustomizations.GroupsSpec do
  @moduledoc """
  A test-only customisation spec declaring the shared option groups the
  lighter booking themes are built from, in their canonical order, over a
  light palette that follows the visitor's OS. It is registered with no
  theme, so it is exercised through `Specs`, its generated callbacks and the
  modules that take a spec. `Tymeslot.Test.ProbeThemeSpec` declares the same
  groups on a registered test theme once each has its dashboard panel.
  """
  use Tymeslot.ThemeCustomizations.Spec

  alias Tymeslot.ThemeCustomizations.Options.Accent
  alias Tymeslot.ThemeCustomizations.Options.Palette
  alias Tymeslot.ThemeCustomizations.Spec

  @accents ~w(tymeslot cobalt indigo violet rose ember emerald teal graphite)

  @impl Spec
  def option_groups,
    do: [
      %{key: :palette, module: Palette, schemes: [], seed_mode: :light, follow_os: true},
      %{key: :accent, module: Accent, presets: @accents, default: "tymeslot"}
    ]

  # With a seed stored the palette leaves the scheme name unconstrained; the
  # name is only there because `Palette.tokens/3` resolves a seed alongside one.
  @impl Spec
  def defaults,
    do: %{color_scheme: "custom", custom_palette_seed: "#b4532a", accent: "tymeslot"}
end
