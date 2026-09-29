defmodule TymeslotWeb.Test.FixtureTheme.Theme do
  @moduledoc """
  A test-only booking theme, registered by `config/test.exs` through
  `:extra_themes`. It is shaped unlike Quill and Rhythm on purpose (a light
  palette with no presets, no background, an option group, a dashboard panel
  and an event of its own) and has no stylesheet; `theme_openness_test.exs`
  uses it to prove a new theme attaches without editing shared code. It
  borrows Quill's preview image, since the contract test wants one that
  exists.
  """
  use TymeslotWeb.Themes.Core.Theme,
    live_view: TymeslotWeb.Test.FixtureTheme.Scheduling.Live,
    preview_image: "/images/ui/theme-previews/quill-theme-preview.webp",
    description: dgettext_noop("dashboard_appearance", "Test fixture theme."),
    option_panels: %{
      Tymeslot.Test.FixtureThemeSpec.Emblem => TymeslotWeb.Test.FixtureTheme.EmblemPanel
    }
end
