defmodule Tymeslot.Test.ProbeThemeSpec do
  @moduledoc """
  Customisation spec of the test-only probe theme (id "98", key `:probe`),
  registered by `config/test.exs` (`TymeslotWeb.Test.ProbeTheme.Theme`),
  which borrows the fixture theme's booking, meeting and poll pages.

  It declares the shared option groups that have a built-in dashboard panel,
  over the light tones, following the visitor's OS, so the dashboard and
  the booking page show each group through the real routes before the
  fixture theme takes them all on.
  `Tymeslot.Test.ThemeCustomizations.GroupsSpec` declares the same groups as
  a spec of no theme.
  """
  use Tymeslot.ThemeCustomizations.Spec

  alias Tymeslot.ThemeCustomizations.Options.Accent
  alias Tymeslot.ThemeCustomizations.Options.ColourMode
  alias Tymeslot.ThemeCustomizations.Options.Density
  alias Tymeslot.ThemeCustomizations.Options.Font
  alias Tymeslot.ThemeCustomizations.Options.Palette
  alias Tymeslot.ThemeCustomizations.Options.Radius
  alias Tymeslot.ThemeCustomizations.Spec

  @accents ~w(tymeslot cobalt indigo violet rose ember emerald teal graphite)

  @impl Spec
  def option_groups,
    do: [
      %{
        key: :palette,
        module: Palette,
        schemes: ~w(neutral cool warm),
        seed_mode: :light,
        follow_os: true
      },
      %{key: :colour_mode, module: ColourMode, default: "auto"},
      %{key: :accent, module: Accent, presets: @accents, default: "tymeslot"},
      %{key: :font, module: Font, presets: ~w(system inter plex), default: "system"},
      %{key: :radius, module: Radius, default: "soft"},
      %{key: :density, module: Density, default: "comfortable"}
    ]

  @impl Spec
  def defaults,
    do: %{
      color_scheme: "neutral",
      colour_mode: "auto",
      accent: "tymeslot",
      font: "system",
      radius: "soft",
      density: "comfortable"
    }

  # The tones are chosen with the theme, not in onboarding.
  @impl Spec
  def onboarding_choices, do: nil
end
