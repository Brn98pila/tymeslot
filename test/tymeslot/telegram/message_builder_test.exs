defmodule Tymeslot.Telegram.MessageBuilderTest do
  use Tymeslot.DataCase, async: true

  @moduletag :telegram
  @moduletag :unit

  alias Tymeslot.Telegram.MessageBuilder

  @meeting %{
    attendee_name: "John Smith",
    attendee_email: "john@example.com",
    attendee_timezone: "America/New_York",
    start_time: ~U[2026-03-10 14:00:00Z],
    end_time: ~U[2026-03-10 14:30:00Z],
    event_type: %{name: "30-minute intro call"},
    uid: "abc123",
    video_room_url: nil,
    cancellation_reason: nil
  }

  # The organiser's timezone, deliberately different from the attendee's: these
  # messages land in the organiser's chat, so every time below is theirs.
  @timezone "UTC"

  describe "build_message/3" do
    test "builds meeting.requested message with the deadline to respond by" do
      meeting = Map.put(@meeting, :approval_deadline_at, ~U[2026-03-09 18:00:00Z])
      msg = MessageBuilder.build_message("meeting.requested", meeting, @timezone)
      assert msg =~ "<b>New Booking Request</b>"
      assert msg =~ "John Smith"
      assert msg =~ "Respond by Mon 09 Mar 2026, 18:00"
    end

    test "builds meeting.declined message with the host's reason" do
      meeting = Map.put(@meeting, :decline_reason, "Fully booked <that> week")
      msg = MessageBuilder.build_message("meeting.declined", meeting, @timezone)
      assert msg =~ "<b>Booking Request Declined</b>"
      assert msg =~ "Fully booked &lt;that&gt; week"
    end

    test "builds meeting.request_expired message" do
      msg = MessageBuilder.build_message("meeting.request_expired", @meeting, @timezone)
      assert msg =~ "<b>Booking Request Expired</b>"
      assert msg =~ "slot was released"
    end

    test "builds meeting.created message" do
      msg = MessageBuilder.build_message("meeting.created", @meeting, @timezone)
      assert msg =~ "<b>New Meeting</b>"
      assert msg =~ "John Smith"
      assert msg =~ "Meeting"
      assert msg =~ "john@example.com"
      assert msg =~ "14:00"
    end

    test "builds meeting.cancelled message" do
      meeting = Map.put(@meeting, :cancellation_reason, "Schedule conflict")
      msg = MessageBuilder.build_message("meeting.cancelled", meeting, @timezone)
      assert msg =~ "<b>Meeting Cancelled</b>"
      assert msg =~ "John Smith"
      assert msg =~ "Schedule conflict"
    end

    test "builds meeting.rescheduled message" do
      msg = MessageBuilder.build_message("meeting.rescheduled", @meeting, @timezone)
      assert msg =~ "<b>Meeting Rescheduled</b>"
      assert msg =~ "John Smith"
    end

    test "HTML-escapes user content" do
      meeting = %{@meeting | attendee_name: "<script>alert('xss')</script>"}
      msg = MessageBuilder.build_message("meeting.created", meeting, @timezone)
      refute msg =~ "<script>"
      assert msg =~ "&lt;script&gt;"
    end

    test "includes video link when present" do
      meeting = Map.put(@meeting, :video_room_url, "https://meet.example.com/room")
      msg = MessageBuilder.build_message("meeting.created", meeting, @timezone)
      assert msg =~ "Join video call"
      assert msg =~ "https://meet.example.com/room"
    end

    test "uses attendee_email as fallback name" do
      meeting = %{@meeting | attendee_name: nil}
      msg = MessageBuilder.build_message("meeting.created", meeting, @timezone)
      assert msg =~ "john@example.com"
    end
  end

  describe "build_message/3 — timezone" do
    test "renders times in the organiser's timezone, not the attendee's" do
      msg = MessageBuilder.build_message("meeting.created", @meeting, "Europe/Tallinn")
      assert msg =~ "16:00\u201316:30 (Europe/Tallinn)"
      refute msg =~ "America/New_York"
    end
  end

  describe "build_test_message/0" do
    test "returns a test message" do
      msg = MessageBuilder.build_test_message()
      assert msg =~ "Test"
      assert msg =~ "Tymeslot"
    end
  end
end
