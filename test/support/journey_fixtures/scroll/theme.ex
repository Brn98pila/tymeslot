defmodule TymeslotWeb.Test.JourneyFixtures.Scroll.Theme do
  @moduledoc """
  Fixture Scroll (`"96"`), a test-only booking theme registered by
  `config/test.exs` through `:extra_themes`: a `Continuous` journey, questions
  first. Its meeting, poll and payment pages are the shared defaults, through
  the fixture theme's `page_shell`; it borrows Quill's preview image.
  """
  alias TymeslotWeb.Test.FixtureTheme.Pages

  use TymeslotWeb.Themes.Core.Theme,
    live_view: TymeslotWeb.Test.JourneyFixtures.Scroll.Live,
    preview_image: "/images/ui/theme-previews/quill-theme-preview.webp",
    description: dgettext_noop("dashboard_appearance", "Test fixture theme."),
    page_shell: &Pages.page_shell/1
end
