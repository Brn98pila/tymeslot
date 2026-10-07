defmodule Tymeslot.Availability.RecurringCalendarEventOfferTest do
  @moduledoc """
  The booking page against a recurring event from a CalDAV-shaped calendar,
  expanded by the real read path rather than handed over as occurrences.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :availability
  @moduletag :calendar
  @moduletag :integration

  import Mox
  import Tymeslot.AvailabilityTestHelpers

  alias Tymeslot.Bookings.Create
  alias Tymeslot.CalendarMock
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Integrations.Calendar.EventsRead
  alias Tymeslot.TestMocks

  setup :verify_on_exit!

  setup do
    TestMocks.setup_all_mocks()
    :ok
  end

  # A CalDAV-shaped provider: it returns a recurring event as its master,
  # with the rule, and leaves the expansion to the read path.
  defmodule StandingMeetingProvider do
    @moduledoc false

    @spec list_events(map(), keyword()) :: {:ok, [map()]}
    def list_events(%{first_day: first_day}, _opts) do
      {:ok,
       [
         %{
           uid: "standing-standup",
           summary: "Standup",
           start_time: DateTime.new!(first_day, ~T[11:00:00], "Etc/UTC"),
           end_time: DateTime.new!(first_day, ~T[11:30:00], "Etc/UTC"),
           recurrence_rule: "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR",
           status: "confirmed",
           transparency: "opaque"
         }
       ]}
    end
  end

  describe "a recurring calendar event that began years ago" do
    test "still hides its slot today, and the booking API refuses it" do
      %{user: user, profile: profile} = create_bookable_profile(timezone: "Etc/UTC")
      target_date = next_bookable_weekday()

      # Three years of weekdays is far more occurrences than one expansion
      # returns, so the series has to be moved forward to the range rather
      # than counted from its first day.
      client = %{
        provider_type: :fake,
        provider_module: StandingMeetingProvider,
        client: %{calendar_path: "/cal/standing", first_day: Date.add(target_date, -3 * 364)}
      }

      TestMocks.stub_no_calendar_events()
      assert "11:00 AM" in offered(profile, target_date, "30min")

      # The stub hands the range to the real read path, which expands the rule.
      stub(CalendarMock, :get_events_for_range_fresh, fn _user_id, start_date, end_date ->
        {:ok, events, _path} =
          EventsRead.fetch_events_with_fallback(
            client,
            DateTime.new!(start_date, ~T[00:00:00], "Etc/UTC"),
            DateTime.new!(end_date, ~T[23:59:59], "Etc/UTC")
          )

        {:ok, events}
      end)

      AvailabilityCache.invalidate_for_user(user.id)
      slots = offered(profile, target_date, "30min")

      refute "11:00 AM" in slots
      assert "12:00 PM" in slots

      assert {:error, :slot_taken} =
               Create.execute(
                 %{
                   date: target_date,
                   time: "11:00 AM",
                   duration: "30min",
                   user_timezone: "Etc/UTC",
                   organizer_user_id: user.id
                 },
                 %{
                   "name" => "Standup Attendee",
                   "email" => "standup-attendee@example.com",
                   "message" => "Booking over a standing meeting"
                 }
               )
    end
  end
end
