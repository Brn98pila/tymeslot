defmodule TymeslotWeb.Test.ShowcaseTheme.Theme do
  @moduledoc """
  A second test-only booking theme, registered by `config/test.exs` through
  `:extra_themes`. Its spec, `Tymeslot.Test.ShowcaseThemeSpec`, offers
  Quill's options plus the shared logo and cover groups, which no shipped
  theme offers yet, so their dashboard panels and uploads are proved through
  the real routes. Its booking, meeting and poll pages are the fixture theme's;
  only its payment return shells are its own, because the payment return
  suite tells themes apart by them.
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
