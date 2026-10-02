defmodule TymeslotWeb.AccountDeletion.FrozenPublicPagesTest do
  use TymeslotWeb.ConnCase, async: false

  @moduletag :bookings
  @moduletag :integration

  import Phoenix.LiveViewTest
  import Tymeslot.AvailabilityTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Auth.UserQueries
  alias Tymeslot.Bookings.Create
  alias Tymeslot.Meetings.ApprovalToken
  alias Tymeslot.Meetings.Guests
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Profiles.ProfileQueries
  alias Tymeslot.Repo

  defp freeze(user) do
    now = DateTime.utc_now(:second)
    {:ok, pending} = UserQueries.mark_deletion_scheduled(user, now, DateTime.add(now, 14, :day))
    pending
  end

  defp held_meeting(user) do
    insert(:meeting,
      status: "awaiting_approval",
      organizer_user: user,
      organizer_user_id: user.id,
      attendee_name: "Alex Guest",
      attendee_email: "alex@example.com",
      approval_requested_at: DateTime.utc_now(:second),
      approval_deadline_at: DateTime.add(DateTime.utc_now(:second), 12, :hour)
    )
  end

  test "the booking page of a host pending deletion is a 404", %{conn: conn} do
    user = insert(:user)
    insert(:profile, user: user, username: "frozen-page")
    freeze(user)

    assert_error_sent(404, fn -> get(conn, "/frozen-page") end)
  end

  test "the free/busy feed and the .ics download of a host pending deletion are 404", %{
    conn: conn
  } do
    user = insert(:user)
    profile = insert(:profile, user: user, username: "frozen-feed")
    {:ok, _profile} = ProfileQueries.update_freebusy_token(profile, "frozen-feed-token")
    meeting = insert(:meeting, organizer_user: user, organizer_email: user.email)

    assert conn |> get("/free-busy/frozen-feed-token") |> response(200)
    freeze(user)

    assert conn |> get("/free-busy/frozen-feed-token") |> response(404)

    assert conn
           |> get("/frozen-feed/meeting/#{meeting.uid}/calendar.ics")
           |> response(404)
  end

  describe "the booking request link in the host's email" do
    test "shows nothing of the request once the host's account is pending deletion",
         %{conn: conn} do
      user = insert(:user)
      meeting = held_meeting(user)
      path = "/meeting-request/" <> ApprovalToken.sign(meeting)

      {:ok, _view, html} = live(conn, path)
      assert html =~ "Approve booking"

      freeze(user)

      {:ok, _view, html} = live(conn, path)
      assert html =~ "Link not recognised"
      refute html =~ "Alex Guest"
      refute html =~ "Approve booking"
    end

    test "cannot be answered from a page opened before the freeze", %{conn: conn} do
      user = insert(:user)
      meeting = held_meeting(user)

      {:ok, view, _html} = live(conn, "/meeting-request/" <> ApprovalToken.sign(meeting))
      freeze(user)

      html = view |> element("[data-testid='approve-request']") |> render_click()

      assert html =~ "Link not recognised"
      refute html =~ "changed since"
      assert Repo.get!(MeetingSchema, meeting.id).status == "awaiting_approval"
    end
  end

  test "a booking for a host pending deletion is refused" do
    %{user: user} = create_always_bookable_profile(timezone: "America/New_York")
    freeze(user)

    meeting_params = %{
      date: Date.add(Date.utc_today(), 1),
      time: "14:00",
      duration: "60min",
      user_timezone: "America/New_York",
      organizer_user_id: user.id
    }

    form_data = %{"name" => "Guest", "email" => "guest@example.com", "message" => ""}

    assert Create.execute(meeting_params, form_data, skip_calendar_check: true) ==
             {:error, :host_not_found}
  end

  test "an RSVP link of a host pending deletion behaves as unknown" do
    user = insert(:user)
    meeting = insert(:meeting, organizer_user: user, organizer_email: user.email)
    {:ok, [guest]} = Guests.create_for_meeting(meeting.id, ["guest@example.com"])
    freeze(user)

    assert Guests.get_open_invitation(guest.rsvp_token) == {:error, :not_found}
  end
end
