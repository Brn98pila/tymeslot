defmodule TymeslotWeb.Test.JourneyFixtures.Talk.Live do
  @moduledoc """
  Fixture Talk's scheduling LiveView: a conversation on
  `Navigators.Transcript`. The opening moment chooses the meeting type of an
  organiser who offers only one (`:only`), so that visitor starts at the
  meeting type's questions, or at the day when it has none; then a factless
  "which day?" moment, the times, and the details.
  """

  alias TymeslotWeb.Test.JourneyFixtures.Moments.{Ask, Confirmation, Day, Offer, Time, You}
  alias TymeslotWeb.Test.JourneyFixtures.Wrapper
  alias TymeslotWeb.Themes.Shared.Journey.Navigators.Transcript

  use TymeslotWeb.Themes.Shared.SchedulingLive,
    wrapper: &Wrapper.talk/1,
    journey: [
      navigator: Transcript,
      moments: [
        {:hello, collects: [:meeting_type], component: Offer, defaults: [meeting_type: :only]},
        {:ask, collects: [:answers], component: Ask},
        {:day, collects: [], component: Day},
        {:time, collects: [:slot], component: Time},
        {:you, collects: [:attendee], component: You}
      ],
      outcomes: %{confirmation: Confirmation, awaiting_payment: :shared}
    ]
end

defmodule TymeslotWeb.Test.JourneyFixtures.Talk.Theme do
  @moduledoc """
  Fixture Talk (`"95"`), a test-only booking theme registered by
  `config/test.exs` through `:extra_themes`: a `Transcript` journey whose
  meeting type is chosen for a visitor of an organiser who offers one. Its
  meeting, poll and payment pages are the shared defaults, through the
  fixture theme's `page_shell`; it borrows Quill's preview image.
  """
  alias TymeslotWeb.Test.FixtureTheme.Pages

  use TymeslotWeb.Themes.Core.Theme,
    live_view: TymeslotWeb.Test.JourneyFixtures.Talk.Live,
    preview_image: "/images/ui/theme-previews/quill-theme-preview.webp",
    description: dgettext_noop("dashboard_appearance", "Test fixture theme."),
    page_shell: &Pages.page_shell/1
end
