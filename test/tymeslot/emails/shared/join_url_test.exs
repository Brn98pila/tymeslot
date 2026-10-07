defmodule Tymeslot.Emails.Shared.JoinUrlTest do
  use ExUnit.Case, async: true
  @moduletag :emails
  @moduletag :unit

  alias Tymeslot.Emails.Shared.JoinUrl

  @details %{
    meeting_url: "https://meet.example.com/room",
    organizer_video_url: "https://meet.example.com/room?role=host",
    attendee_video_url: "https://meet.example.com/room?role=participant",
    guest_video_url: "https://meet.example.com/room?role=guest"
  }

  describe "for/2" do
    test "gives each role its own link" do
      assert JoinUrl.for(:organizer, @details) == @details.organizer_video_url
      assert JoinUrl.for(:attendee, @details) == @details.attendee_video_url
      assert JoinUrl.for(:guest, @details) == @details.guest_video_url
    end

    test "falls back to the room URL for the organiser and guests only" do
      details = %{meeting_url: "https://meet.example.com/room"}

      assert JoinUrl.for(:organizer, details) == "https://meet.example.com/room"
      assert JoinUrl.for(:guest, details) == "https://meet.example.com/room"
      assert JoinUrl.for(:attendee, details) == nil
    end
  end

  describe "with_room_fallback/2" do
    test "prefers the role's own link" do
      assert JoinUrl.with_room_fallback(:attendee, @details) == @details.attendee_video_url
    end

    test "falls back to the room URL when the role has no link" do
      assert JoinUrl.with_room_fallback(:attendee, %{meeting_url: "https://meet.example.com/room"}) ==
               "https://meet.example.com/room"
    end

    test "is nil when there is no room at all" do
      assert JoinUrl.with_room_fallback(:attendee, %{}) == nil
    end
  end
end
