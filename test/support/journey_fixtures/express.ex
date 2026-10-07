defmodule TymeslotWeb.Test.JourneyFixtures.Express.Live do
  @moduledoc """
  Fixture Express's scheduling LiveView: a time-first journey on
  `Navigators.Paged`. The first moment collects the meeting type and the
  slot, the type defaulted to the organiser's first; the second asks the
  meeting type's questions, when it has some, above the details.
  """

  alias TymeslotWeb.Test.JourneyFixtures.Moments.{Confirmation, Now, You}
  alias TymeslotWeb.Test.JourneyFixtures.Wrapper
  alias TymeslotWeb.Themes.Shared.Journey.Navigators.Paged

  use TymeslotWeb.Themes.Shared.SchedulingLive,
    wrapper: &Wrapper.express/1,
    journey: [
      navigator: Paged,
      moments: [
        {:now,
         collects: [:meeting_type, :slot], component: Now, defaults: [meeting_type: :first]},
        {:you, collects: [:answers, :attendee], component: You}
      ],
      outcomes: %{confirmation: Confirmation, awaiting_payment: :shared}
    ]
end

defmodule TymeslotWeb.Test.JourneyFixtures.Express.Theme do
  @moduledoc """
  Fixture Express (`"94"`), a test-only booking theme registered by
  `config/test.exs` through `:extra_themes`: a time-first `Paged` journey. Its
  meeting, poll and payment pages are the shared defaults, through the
  fixture theme's `page_shell`; it borrows Quill's preview image.
  """
  alias TymeslotWeb.Test.FixtureTheme.Pages

  use TymeslotWeb.Themes.Core.Theme,
    live_view: TymeslotWeb.Test.JourneyFixtures.Express.Live,
    preview_image: "/images/ui/theme-previews/quill-theme-preview.webp",
    description: dgettext_noop("dashboard_appearance", "Test fixture theme."),
    page_shell: &Pages.page_shell/1
end
