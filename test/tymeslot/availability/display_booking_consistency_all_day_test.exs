defmodule Tymeslot.Availability.DisplayBookingConsistencyAllDayTest do
  @moduledoc """
  The display and the submit-time calendar check must place an all-day event
  on the same stretch of time: the host's local day.

  Companion to `DisplayBookingConsistencyTest`, split out to keep that module
  under the size limit. A host far from UTC exposes any path that anchors the
  event's dates at UTC midnight instead: Sydney's morning is the previous UTC
  day, so such a path refuses the morning after the event, which the booking
  page offers, and lets through the morning of the event itself.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :availability
  @moduletag :integration

  import Mox
  import Tymeslot.AvailabilityTestHelpers

  alias Tymeslot.Availability.TimeSlots
  alias Tymeslot.Bookings.{CalendarCheck, Create, Policy}
  alias Tymeslot.CalendarMock
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.TestMocks

  @timezone "Australia/Sydney"

  setup :verify_on_exit!

  setup do
    TestMocks.setup_all_mocks()

    %{user: user, profile: profile} = create_always_bookable_profile(timezone: @timezone)
    meeting_type = insert(:meeting_type, user: user, duration_minutes: 30)
    holiday = Date.add(Date.utc_today(), 10)

    stub(CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end ->
      {:ok,
       [
         %{
           uid: "holiday-#{System.unique_integer([:positive])}",
           start_time: holiday,
           end_time: Date.add(holiday, 1),
           all_day: true,
           status: "confirmed",
           transparency: "opaque",
           summary: "Public holiday"
         }
       ]}
    end)

    %{user: user, profile: profile, meeting_type: meeting_type, holiday: holiday}
  end

  test "the morning after an all-day event is offered and accepted",
       %{user: user, profile: profile, meeting_type: meeting_type, holiday: holiday} do
    day_after = Date.add(holiday, 1)
    config = Policy.scheduling_config(user.id, meeting_type)

    # 09:00 and 10:00 in Sydney are still the holiday's date in UTC.
    for time <- ["9:00 AM", "10:00 AM"] do
      assert time in offered(profile, day_after, "30min", meeting_type: meeting_type)
      assert CalendarCheck.probe(slot(user, day_after, time), config) == :ok
    end

    assert {:ok, %MeetingSchema{status: "confirmed"}} =
             book_at(user, meeting_type, day_after, "9:00 AM")
  end

  test "the morning of an all-day event is hidden and refused",
       %{user: user, profile: profile, meeting_type: meeting_type, holiday: holiday} do
    config = Policy.scheduling_config(user.id, meeting_type)

    assert offered(profile, holiday, "30min", meeting_type: meeting_type) == []

    for time <- ["9:00 AM", "10:00 AM"] do
      assert CalendarCheck.probe(slot(user, holiday, time), config) ==
               {:error, :slot_unavailable}
    end

    assert {:error, :slot_taken} = book_at(user, meeting_type, holiday, "9:00 AM")
  end

  defp slot(user, date, time) do
    start = DateTime.new!(date, TimeSlots.parse_time_slot(time), @timezone)

    %{
      organizer_user_id: user.id,
      start_datetime: start,
      end_datetime: DateTime.add(start, 30, :minute)
    }
  end

  defp book_at(user, meeting_type, date, time) do
    Create.execute(
      %{
        date: date,
        time: time,
        duration: "30min",
        user_timezone: @timezone,
        organizer_user_id: user.id,
        meeting_type_id: meeting_type.id
      },
      %{
        "name" => "Holiday Attendee",
        "email" => "holiday-#{System.unique_integer([:positive])}@example.com",
        "message" => "Booking around a public holiday"
      }
    )
  end
end
