defmodule Tymeslot.Test.ProbeThemeSpec do
  @moduledoc """
  Customisation spec of the test-only probe theme (id "98", key `:probe`),
  registered by `config/test.exs` (`TymeslotWeb.Test.ProbeTheme.Theme`),
  which borrows the fixture theme's booking, meeting and poll pages.

  It declares the shared option groups that have a built-in dashboard panel,
  over a light palette that follows the visitor's OS, so the dashboard and
  the booking page show each group through the real routes before the
  fixture theme takes them all on.
  `Tymeslot.Test.ThemeCustomizations.GroupsSpec` declares the same groups as
  a spec of no theme.
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

  # No preset schemes, so the onboarding wizard has nothing to offer.
  @impl Spec
  def onboarding_choices, do: nil
end
