defmodule TymeslotWeb.Dashboard.BookingsManagementRefusalTest do
  @moduledoc """
  The host asking to cancel or reschedule a booking the booking rules no
  longer allow: the modal stays shut and the refusal is shown as copy, never
  as the domain's reason term.
  """

  use TymeslotWeb.LiveCase, async: false

  import Phoenix.LiveViewTest
  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  @moduletag :bookings
  @moduletag :live

  alias Plug.Test

  setup %{conn: conn} do
    host = insert(:user, onboarding_completed_at: DateTime.utc_now(:second))
    insert(:profile, user: host)
    conn = conn |> Test.init_test_session(%{}) |> fetch_session() |> log_in_user(host)

    {:ok, conn: conn, host: host}
  end

  test "cancelling a meeting already under way is refused with the reason", ctx do
    meeting = started_meeting(ctx.host)
    view = open_meetings(ctx.conn)

    html = push_to_component(view, "show_cancel_modal", %{"id" => meeting.id})

    refute has_element?(view, "#cancel-meeting-form")
    assert html =~ "Cannot cancel a meeting that has already started"
  end

  test "asking to reschedule a meeting already under way is refused with the reason", ctx do
    meeting = started_meeting(ctx.host)
    view = open_meetings(ctx.conn)

    html = push_to_component(view, "show_reschedule_modal", %{"id" => meeting.id})

    refute render(view) =~ "Send a reschedule request to"
    assert html =~ "Cannot reschedule a meeting that has already started"
  end

  defp started_meeting(host) do
    now = DateTime.utc_now(:second)

    insert(:meeting,
      status: "confirmed",
      organizer_user: host,
      organizer_user_id: host.id,
      organizer_email: host.email,
      attendee_name: "Alex Guest",
      attendee_email: "alex@example.com",
      start_time: DateTime.add(now, -10, :minute),
      end_time: DateTime.add(now, 50, :minute)
    )
  end

  defp push_to_component(view, event, params) do
    view |> with_target("#bookings-management") |> render_click(event, params)
    render(view)
  end

  defp open_meetings(conn) do
    {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")
    view
  end
end
