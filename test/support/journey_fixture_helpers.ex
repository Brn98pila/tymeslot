defmodule Tymeslot.JourneyFixtureHelpers do
  @moduledoc """
  Seeding and waits for the journey fixture themes' tests
  (`test/support/journey_fixtures/`, `"96"` Fixture Scroll first).

  The pages are driven through `TymeslotWeb.BookingDriver`; this module only
  seeds the organiser, reads the LiveView's assigns and the rendered markup,
  and waits for what arrives asynchronously (the month's availability, a
  day's times, the confirmation).
  """

  import ExUnit.Assertions, only: [flunk: 1]
  import Phoenix.LiveViewTest
  import Tymeslot.Factory

  alias Tymeslot.MeetingTypes
  alias Tymeslot.TestHelpers.Eventually
  alias TymeslotWeb.BookingDriver.Page

  @doc """
  A booking-ready organiser on `theme_id`: a profile in UTC, availability
  every day from 09:00 to 17:00 up to 30 days ahead, an active calendar
  integration, and the meeting types in `opts[:types]` (keyword lists for the
  factory, plus `:custom_fields`, a list of question definitions), by default
  one 30-minute "Quick Chat". `opts[:profile]` adds fields to the profile.
  Returns `%{user:, profile:, meeting_types:}`, the types in order.
  """
  @spec seed_organiser(String.t(), String.t(), keyword()) :: map()
  def seed_organiser(theme_id, username, opts \\ []) do
    user = insert(:user)

    profile =
      insert(
        :profile,
        [user: user, username: username, booking_theme: theme_id, timezone: "UTC"] ++
          Keyword.get(opts, :profile, [])
      )

    schedule =
      insert(:availability_schedule,
        profile: profile,
        is_default: true,
        advance_booking_days: 30,
        min_advance_hours: 0,
        buffer_minutes: 0
      )

    for day_of_week <- 1..7 do
      insert(:weekly_availability,
        schedule: schedule,
        day_of_week: day_of_week,
        is_available: true,
        start_time: ~T[09:00:00],
        end_time: ~T[17:00:00]
      )
    end

    insert(:calendar_integration, user: user, is_active: true)

    meeting_types =
      opts
      |> Keyword.get(:types, [[name: "Quick Chat", duration_minutes: 30]])
      |> Enum.with_index()
      |> Enum.map(fn {attrs, index} -> insert_meeting_type(user, attrs, index) end)

    %{user: user, profile: profile, meeting_types: meeting_types}
  end

  defp insert_meeting_type(user, attrs, index) do
    {questions, attrs} = Keyword.pop(attrs, :custom_fields, [])

    meeting_type =
      insert(:meeting_type, [user: user, is_active: true, sort_order: index] ++ attrs)

    case questions do
      [] ->
        meeting_type

      questions ->
        {:ok, meeting_type} =
          MeetingTypes.update_meeting_type(meeting_type, %{"custom_fields" => questions})

        meeting_type
    end
  end

  @doc "The LiveView's assigns."
  @spec live_assigns(Phoenix.LiveViewTest.View.t()) :: map()
  defdelegate live_assigns(view), to: Page, as: :assigns

  @doc "Waits until `selector` is on the page."
  @spec await(Phoenix.LiveViewTest.View.t(), String.t()) :: true
  def await(view, selector),
    do: Eventually.eventually(fn -> has_element?(view, selector) end, timeout: 5000)

  @doc "Waits until the month's availability has arrived (or failed)."
  @spec await_availability(Phoenix.LiveViewTest.View.t()) :: true
  def await_availability(view) do
    Eventually.eventually(
      fn -> live_assigns(view)[:availability_status] in [:loaded, :error] end,
      timeout: 5000
    )
  end

  @doc "The first value of `attr` on the elements `selector` matches, or nil."
  @spec first_value(Phoenix.LiveViewTest.View.t(), String.t(), String.t()) :: String.t() | nil
  def first_value(view, selector, attr),
    do: view |> Page.attribute(selector, attr) |> List.first()

  @doc """
  Waits for the chosen day's times (the page lands the visitor on their first
  free day by itself) and returns the first, a `data-fact="time"` value.
  """
  @spec await_first_time(Phoenix.LiveViewTest.View.t()) :: String.t()
  def await_first_time(view) do
    await(view, "[data-fact='time']")
    first_value(view, "[data-fact='time']", "data-value")
  end

  @doc """
  A free day other than `except` among the date buttons on the page, moving
  the month calendar on once when the month shown has none.
  """
  @spec another_free_date(Phoenix.LiveViewTest.View.t(), String.t()) :: String.t()
  def another_free_date(view, except) do
    case free_dates(view) -- [except] do
      [date | _rest] ->
        date

      [] ->
        view |> element("[data-intent='later']:not([disabled])") |> render_click()
        await_availability(view)

        case free_dates(view) -- [except] do
          [date | _rest] -> date
          [] -> flunk("Expected another free day within two months")
        end
    end
  end

  defp free_dates(view),
    do: Page.attribute(view, "[data-fact='date']:not([disabled])", "data-value")
end
