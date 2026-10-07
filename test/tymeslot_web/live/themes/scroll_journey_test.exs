defmodule TymeslotWeb.Live.Themes.ScrollJourneyTest do
  @moduledoc """
  Bookings through Fixture Scroll (`"96"`, `test/support/journey_fixtures/`),
  a journey on `Navigators.Continuous` that asks a meeting type's questions
  before it shows the calendar. Driven through the markup contract
  (`TymeslotWeb.BookingDriver`), asserted on the moments' states
  (`data-moment-state`) and on the meetings stored.
  """
  use TymeslotWeb.LiveCase, async: false

  @moduletag :bookings
  @moduletag :themes
  @moduletag :integration

  import Mox
  import Tymeslot.JourneyFixtureHelpers

  alias Tymeslot.CalendarMock
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.TestMocks
  alias TymeslotWeb.BookingDriver

  @theme_id "96"

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    AvailabilityCache.clear_all()
    TestMocks.setup_all_mocks()

    CalendarMock
    |> stub(:get_events_for_range_fresh, fn _user_id, _start, _end -> {:ok, []} end)
    |> stub(:get_booking_integration_info, fn _user_id -> {:error, :no_integration} end)

    :ok
  end

  defp state(view, moment), do: first_value(view, "##{moment}-step", "data-moment-state")

  describe "the page" do
    test "keeps its moments on one page in the navigator's frame", %{conn: conn} do
      %{profile: profile} = seed_organiser(@theme_id, "scroll-frame")
      {:ok, view, _html} = live(conn, ~p"/#{profile.username}")

      assert has_element?(view, ".journey-fixture-scroll div.journey--continuous > #intro-step")
      assert state(view, :intro) == "open"
      assert state(view, :offer) == "current"
      refute has_element?(view, "#when-step")
    end
  end

  describe "a meeting type without questions" do
    test "opens the calendar straight after the meeting type", %{conn: conn} do
      %{profile: profile} = seed_organiser(@theme_id, "scroll-no-questions")
      {:ok, view, _html} = live(conn, ~p"/#{profile.username}")

      BookingDriver.choose_meeting_type(view, "quick-chat")

      refute has_element?(view, "#ask-step")
      assert state(view, :when) == "current"

      # Opened, not merely shown: the calendar lands on the first free day
      # and that day's times come up.
      assert is_binary(await_first_time(view))

      # A page that opens its moments by itself keeps the language switcher
      # past its first moment.
      assert has_element?(view, ".journey-fixture-language.visible")
    end
  end
end
