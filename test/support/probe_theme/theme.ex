defmodule TymeslotWeb.Test.ProbeTheme.Theme do
  @moduledoc """
  A second test-only booking theme, registered by `config/test.exs` through
  `:extra_themes`. Its spec, `Tymeslot.Test.ProbeThemeSpec`, declares the
  shared option groups that have a built-in dashboard panel, so each is
  proved through the real routes before a theme offers it. Its booking,
  meeting and poll pages are the fixture theme's; only its payment return
  shells are its own, because the payment return suite tells themes apart by
  them.
  """
  use TymeslotWeb.Themes.Core.Theme,
    live_view: TymeslotWeb.Test.FixtureTheme.Scheduling.Live,
    preview_image: "/images/ui/theme-previews/quill-theme-preview.webp",
    description: dgettext_noop("dashboard_appearance", "Test fixture theme.")

  alias TymeslotWeb.Test.FixtureTheme.Theme, as: FixtureTheme

  @impl TymeslotWeb.Themes.Core.Behaviour
  defdelegate render_meeting_action(assigns, action), to: FixtureTheme

  @impl TymeslotWeb.Themes.Core.Behaviour
  defdelegate render_poll_action(assigns), to: FixtureTheme
end
