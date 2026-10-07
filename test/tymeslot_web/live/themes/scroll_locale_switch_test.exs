defmodule TymeslotWeb.Live.Themes.ScrollLocaleSwitchTest do
  @moduledoc """
  A language switch on Fixture Scroll (`"96"`), a `Continuous` journey whose
  language switcher shows on every moment. The switch is a full redirect, so
  the page that comes back knows only what the URL carries: the meeting type,
  the day and the time ride along, and the page lands where the visitor was,
  on the route the visit started on, so a type chosen on the overview stays
  revisitable and a direct or private link's stays locked.
  """
  use TymeslotWeb.LiveCase, async: false

  @moduletag :bookings
  @moduletag :themes
  @moduletag :i18n
  @moduletag :integration

  import Mox
  import Tymeslot.JourneyFixtureHelpers

  alias Tymeslot.CalendarMock
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.TestHelpers.Eventually
  alias Tymeslot.TestMocks
  alias TymeslotWeb.BookingDriver
  alias TymeslotWeb.Themes.Shared.Journey.Facts.MeetingType

  @theme_id "96"

  @types [
    [name: "Quick Chat", duration_minutes: 30],
    [name: "Long Chat", duration_minutes: 60]
  ]

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    RateLimiter.clear_all()
    AvailabilityCache.clear_all()
    TestMocks.setup_all_mocks()

    CalendarMock
    |> stub(:get_events_for_range_fresh, fn _user_id, _start, _end -> {:ok, []} end)
    |> stub(:get_booking_integration_info, fn _user_id -> {:error, :no_integration} end)

    :ok
  end

  defp state(view, moment), do: first_value(view, "##{moment}-step", "data-moment-state")

  # Chooses the type and the first free time, and returns the day and time.
  defp choose(view, slug) do
    BookingDriver.choose_meeting_type(view, slug)
    BookingDriver.pick_time(view, await_first_time(view))
    Map.take(live_assigns(view), [:selected_date, :selected_time])
  end

  # Drives the real switcher and follows its external redirect; returns the
  # path it redirected to and the page mounted there.
  defp switch_language(view, conn, locale) do
    view |> element("button[phx-click='toggle_language_dropdown']") |> render_click()

    {:ok, conn} =
      view
      |> element("button[phx-click='change_locale'][phx-value-locale='#{locale}']")
      |> render_click()
      |> follow_redirect(conn)

    {:ok, view, _html} = live(conn)
    {conn.request_path, view}
  end

  defp await_moment(view, moment, wanted) do
    Eventually.eventually(fn -> state(view, moment) == wanted end, timeout: 5000)
  end

  describe "a switch after choosing on the overview" do
    test "keeps the meeting type, the day and the time, and lands on the details",
         %{conn: conn} do
      %{profile: profile} = seed_organiser(@theme_id, "scroll-locale-overview", types: @types)
      {:ok, view, _html} = live(conn, ~p"/#{profile.username}")

      chosen = choose(view, "quick-chat")
      {path, view} = switch_language(view, conn, "de")

      assert path == "/#{profile.username}"
      assert has_element?(view, "[data-locale='de']")
      await_moment(view, :you, "current")

      assigns = live_assigns(view)
      assert assigns.selected_duration == "quick-chat"
      assert Map.take(assigns, [:selected_date, :selected_time]) == chosen
      assert state(view, :offer) == "done"
      assert state(view, :when) == "done"

      # Came through the overview, so the meeting type may still be changed.
      assert assigns.entered_via_overview
      assert MeetingType.revisitable?(assigns)
    end

    @tag :capture_log
    test "drops a time that was taken meanwhile and keeps the day", %{conn: conn} do
      %{profile: profile} = seed_organiser(@theme_id, "scroll-locale-taken", types: @types)
      {:ok, view, _html} = live(conn, ~p"/#{profile.username}")

      chosen = choose(view, "quick-chat")

      # Someone else books that very time first.
      {:ok, other, _html} = live(build_conn(), ~p"/#{profile.username}")

      BookingDriver.book(other,
        meeting_type: "quick-chat",
        date: chosen.selected_date,
        time: chosen.selected_time,
        attendee: %{name: "Grace Hopper", email: "grace@example.com"}
      )

      assert Repo.get_by(MeetingSchema, attendee_email: "grace@example.com")
      AvailabilityCache.clear_all()

      {_path, view} = switch_language(view, conn, "de")
      await_moment(view, :when, "current")

      assigns = live_assigns(view)
      assert assigns.selected_duration == "quick-chat"
      assert assigns.selected_date == chosen.selected_date
      assert assigns.selected_time == nil
      refute has_element?(view, "#you-step")
    end
  end

  describe "a switch on a meeting type's own link" do
    test "keeps the day and the time, and the type stays locked", %{conn: conn} do
      %{profile: profile} = seed_organiser(@theme_id, "scroll-locale-direct", types: @types)
      {:ok, view, _html} = live(conn, ~p"/#{profile.username}/long-chat")

      chosen = choose(view, "long-chat")
      {path, view} = switch_language(view, conn, "de")

      assert path == "/#{profile.username}/long-chat"
      await_moment(view, :you, "current")

      assigns = live_assigns(view)
      assert assigns.selected_duration == "long-chat"
      assert Map.take(assigns, [:selected_date, :selected_time]) == chosen
      refute assigns.entered_via_overview
      refute MeetingType.revisitable?(assigns)
    end
  end

  describe "a private meeting type" do
    setup do
      %{profile: profile, meeting_types: [_public, private]} =
        seed_organiser(@theme_id, "scroll-locale-private",
          types: [[name: "Quick Chat", duration_minutes: 30], [name: "Secret", is_private: true]]
        )

      %{profile: profile, slug: MeetingTypes.effective_slug(private)}
    end

    test "is not chosen by naming it on the overview", %{conn: conn, profile: profile, slug: slug} do
      {:ok, view, _html} =
        live(conn, ~p"/#{profile.username}?duration=#{slug}&entered_via_overview=true&locale=de")

      assert state(view, :offer) == "current"
      refute has_element?(view, "#when-step")
      refute has_element?(view, "[data-fact='meeting_type'][data-value='#{slug}']")
    end

    test "stays locked on its own link whatever the URL claims",
         %{conn: conn, profile: profile, slug: slug} do
      {:ok, view, _html} =
        live(conn, ~p"/#{profile.username}/#{slug}?entered_via_overview=true&via=overview")

      assigns = live_assigns(view)
      assert assigns.meeting_type.is_private
      refute assigns.entered_via_overview
      refute MeetingType.revisitable?(assigns)
    end
  end
end
