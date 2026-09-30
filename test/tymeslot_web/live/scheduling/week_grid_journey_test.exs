defmodule TymeslotWeb.Live.Scheduling.WeekGridJourneyTest do
  @moduledoc """
  The two journeys a week view exists for, end to end through a real booking
  page: booking a meeting, and moving one, with the time picked straight from
  the week grid. The fixture theme (`test/support/fixture_theme/`) renders the
  shared `WeekGrid` on its schedule step and a plain booking form on its
  booking step; the grid's `load_week` binding is sent by hand, since
  LiveViewTest runs no JS bindings.

  The load-bearing assertions are in the database: the meeting booked, or the
  meeting moved, starts at exactly the day and time clicked, and a reschedule
  leaves the organiser with one meeting, not two. The page opens on a linked
  day nine days out, so the times clicked exist whatever the hour the suite
  runs at.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :bookings
  @moduletag :scheduling
  @moduletag :integration

  import Ecto.Query, only: [from: 2]
  import Mox
  import Tymeslot.Factory
  import Tymeslot.ThemeBookingFlowHelpers

  alias Tymeslot.CalendarMock
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks

  @fixture_theme_id "99"
  @timezone "Etc/UTC"

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

  @tag :capture_log
  test "a visitor books the time they click on the week grid", %{conn: conn} do
    %{user: user, profile: profile} =
      seed_booking_account(@fixture_theme_id, "week-book", @timezone)

    day = linked_day()

    view = open_week(conn, profile, day)
    pick(view, day, "10:00 AM")
    submit(view, "week-booker@example.com")

    wait_until(fn -> has_element?(view, "[data-testid='fixture-confirmation']") end)

    meeting =
      Repo.get_by!(MeetingSchema,
        organizer_user_id: user.id,
        attendee_email: "week-booker@example.com"
      )

    assert meeting.status == "confirmed"
    assert DateTime.compare(meeting.start_time, at(day, ~T[10:00:00])) == :eq
  end

  @tag :capture_log
  test "a booker moves their meeting to the time they click on the week grid", %{conn: conn} do
    %{user: user, profile: profile} =
      seed_booking_account(@fixture_theme_id, "week-move", @timezone)

    meeting_type = Repo.get_by!(MeetingTypeSchema, user_id: user.id)
    original_start = Date.utc_today() |> Date.add(7) |> at(~T[11:00:00])

    meeting =
      insert(:meeting,
        organizer_user_id: user.id,
        organizer_name: "Week Host",
        meeting_type_id: meeting_type.id,
        attendee_name: "Test Attendee",
        attendee_email: "attendee@example.com",
        attendee_timezone: @timezone,
        start_time: original_start,
        end_time: DateTime.add(original_start, 30, :minute),
        duration: 30,
        status: "confirmed"
      )

    day = linked_day()

    view = open_week(conn, profile, day, [{"reschedule_meeting_uid", meeting.uid}])
    pick(view, day, "2:00 PM")
    submit(view, "attendee@example.com")

    wait_until(fn -> Repo.get!(MeetingSchema, meeting.id).start_time != original_start end)
    wait_until(fn -> has_element?(view, "[data-testid='fixture-confirmation']") end)

    moved = Repo.get!(MeetingSchema, meeting.id)

    assert DateTime.compare(moved.start_time, at(day, ~T[14:00:00])) == :eq
    assert moved.status == "confirmed"

    assert Repo.aggregate(
             from(m in MeetingSchema, where: m.organizer_user_id == ^user.id),
             :count
           ) ==
             1,
           "rescheduling through the week grid must move the meeting, not book a second one"
  end

  # Nine days out: inside the host's 30-day window, and never today.
  defp linked_day, do: Date.add(Date.utc_today(), 9)

  defp at(date, time), do: DateTime.new!(date, time, @timezone)

  # Overview, schedule step, and the week the linked day is in, loaded as
  # the grid's phx-mounted binding would load it.
  defp open_week(conn, profile, day, extra_params \\ []) do
    query =
      URI.encode_query([{"timezone", @timezone}, {"date", Date.to_iso8601(day)} | extra_params])

    {:ok, view, _html} = live(conn, "/#{profile.username}?#{query}")

    view |> element("[data-testid='duration-option']") |> render_click()
    view |> element("[data-testid='next-step']") |> render_click()
    view |> with_target("[data-testid='fixture-schedule']") |> render_click("load_week", %{})
    render_async(view)

    view
  end

  defp pick(view, day, time) do
    view
    |> element(
      "[data-testid='week-slot'][data-date='#{Date.to_iso8601(day)}'][data-time='#{time}']"
    )
    |> render_click()

    view |> element("[data-testid='next-step']") |> render_click()

    assert has_element?(view, "form[data-testid='booking-form']")
  end

  defp submit(view, email) do
    view
    |> form("form[data-testid='booking-form']", %{
      "booking" => %{
        "name" => "Week Booker",
        "email" => email,
        "message" => "Picked from the week grid"
      }
    })
    |> render_submit()
  end
end
