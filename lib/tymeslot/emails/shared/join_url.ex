defmodule Tymeslot.Emails.Shared.JoinUrl do
  @moduledoc """
  Which video join URL each recipient of a booking email is given.

  `Meetings.VideoRooms` mints two per-role join URLs when it provisions a
  room: `organizer_video_url` (provider role "organizer") and
  `attendee_video_url` (provider role "participant"). Each is built from that
  one person's name and email, so it identifies them in the room.
  `meeting_url` is the shared, identity-free room URL.

    * the organiser hosts the call, so they get the host URL;
    * the booker gets the participant URL minted for them;
    * guests are third parties with no URL of their own. Handing them the
      booker's URL would put them in the room under the booker's identity,
      so they get `guest_video_url`, the link
      `Meetings.VideoRooms.guest_join_url/1` builds for a recipient the room
      cannot name. On most providers that is the shared room URL, the same
      link the ICS attachment already advertises; on one whose links carry a
      credential it is that room URL with a token that names nobody and
      confers no moderator rights, because a server enforcing tokens refuses
      the bare URL outright.

  The organiser URL falls back to the room URL: a meeting can carry
  `meeting_url` without the per-role pair (its presence is also what marks a
  booking as a video meeting; `AppointmentBuilder` derives
  `location_type: :video` from it), and the host reaching the room beats no
  join link at all. The guest URL falls back to the room URL for the same
  reason: a payload assembled before `guest_video_url` existed, or by a caller
  that builds its own map, still has a room to point at.
  """

  @type role :: :organizer | :attendee | :guest

  @doc """
  The join URL for `role`, or nil when the payload carries none for it.

  The attendee has no fallback: `for/2` returns nil when no participant URL
  was minted. Callers that prefer the bare room URL to no button at all use
  `with_room_fallback/2`.
  """
  @spec for(role(), map()) :: String.t() | nil
  def for(:organizer, details) do
    Map.get(details, :organizer_video_url) || Map.get(details, :meeting_url)
  end

  def for(:attendee, details), do: Map.get(details, :attendee_video_url)

  def for(:guest, details) do
    Map.get(details, :guest_video_url) || Map.get(details, :meeting_url)
  end

  @doc """
  The join URL for `role`, falling back to the bare room URL (`meeting_url`)
  when the payload carries no link for that role.
  """
  @spec with_room_fallback(role(), map()) :: String.t() | nil
  def with_room_fallback(role, details) do
    __MODULE__.for(role, details) || Map.get(details, :meeting_url)
  end
end
