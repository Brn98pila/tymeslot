defmodule TymeslotWeb.Live.Themes.MeetingLinkRedirectTest do
  @moduledoc """
  Cancel and reschedule links already in inboxes keep working when the host
  renames themselves, and links handed out before the host had a username
  reach the host's page once they have one.
  """
  use TymeslotWeb.LiveCase, async: true

  @moduletag :bookings
  @moduletag :live

  import Tymeslot.Factory

  alias Ecto.UUID
  alias Tymeslot.Bookings.MeetingLinks
  alias Tymeslot.Profiles

  defp host(username) do
    user = insert(:user)
    profile = insert(:profile, user: user, username: username)
    insert(:theme_customization, profile: profile, theme_id: "1")
    %{user: user, profile: profile}
  end

  defp future_meeting(user) do
    start_time = DateTime.utc_now() |> DateTime.add(3600) |> DateTime.truncate(:second)

    insert(:meeting,
      organizer_user_id: user.id,
      status: "confirmed",
      start_time: start_time,
      end_time: DateTime.add(start_time, 3600)
    )
  end

  defp rename!(profile, username) do
    {:ok, profile} = Profiles.update_username(profile, username, profile.user_id)
    profile
  end

  describe "after the host changes username" do
    setup do
      %{user: user, profile: profile} = host("redirect-before")
      meeting = future_meeting(user)
      rename!(profile, "redirect-after")
      %{meeting: meeting}
    end

    test "the link an email now carries opens the cancel page", %{conn: conn, meeting: meeting} do
      path = URI.parse(MeetingLinks.for_meeting(meeting).cancel_url).path

      assert path == "/redirect-after/meeting/#{meeting.uid}/cancel"
      assert {:ok, _view, _html} = live(conn, path)
    end

    test "an old-username cancel link redirects to the current one", %{
      conn: conn,
      meeting: meeting
    } do
      assert {:error, {:redirect, %{to: to}}} =
               live(conn, "/redirect-before/meeting/#{meeting.uid}/cancel")

      assert to == "/redirect-after/meeting/#{meeting.uid}/cancel"
    end

    test "an old-username reschedule link redirects to the current one", %{
      conn: conn,
      meeting: meeting
    } do
      assert {:error, {:redirect, %{to: to}}} =
               live(conn, "/redirect-before/meeting/#{meeting.uid}/reschedule")

      assert to == "/redirect-after/meeting/#{meeting.uid}/reschedule"
    end
  end

  test "an unknown username with an unknown uid is still a 404", %{conn: conn} do
    assert_raise TymeslotWeb.NotFoundError, fn ->
      live(conn, "/nobody-here/meeting/#{UUID.generate()}/cancel")
    end
  end

  describe "a link handed out before the host had a username" do
    setup do
      %{user: user, profile: profile} = host(nil)
      %{meeting: future_meeting(user), profile: profile}
    end

    test "redirects to the host's page once they have one", %{
      conn: conn,
      meeting: meeting,
      profile: profile
    } do
      rename!(profile, "redirect-late")

      conn = get(conn, "/meeting/#{meeting.uid}/cancel")
      assert redirected_to(conn) == "/redirect-late/meeting/#{meeting.uid}/cancel"

      conn = get(build_conn(), "/meeting/#{meeting.uid}/reschedule")
      assert redirected_to(conn) == "/redirect-late/meeting/#{meeting.uid}/reschedule"
    end

    test "is a 404 while the host still has none", %{conn: conn, meeting: meeting} do
      assert_error_sent 404, fn -> get(conn, "/meeting/#{meeting.uid}/cancel") end
    end
  end
end
