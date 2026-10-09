defmodule TymeslotWeb.Dashboard.Availability.TimeOffCardNilTimezoneTest do
  @moduledoc """
  The time-off card for a host who never set a timezone: their hours and time
  off are read on the default zone (`Tymeslot.Profiles.timezone/1`), so a
  booking inside the time off is found, and shown, on that clock.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :availability
  @moduletag :live

  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.Availability.Schedules
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Repo

  setup %{conn: conn} do
    AvailabilityCache.clear_all()
    {:ok, ctx} = setup_dashboard_user(%{conn: conn})
    {:ok, _schedule} = Schedules.create_default(ctx[:profile].id)

    ctx
  end

  describe "a host who never set a timezone" do
    # Their hours and time off are read on the default zone (Tallinn, UTC+3 in
    # July). 00:30 on 5 July in Tallinn is 21:30 UTC on the 4th.
    setup %{profile: profile} do
      profile |> Changeset.change(timezone: nil) |> Repo.update!()
      :ok
    end

    test "sees a booking inside the time off on the clock it is read on", %{
      conn: conn,
      user: user
    } do
      booking(user, ~U[2027-07-04 21:30:00Z], "Night call")

      {:ok, view, _html} = live(conn, ~p"/dashboard/availability")
      view |> element("[data-testid='add-time-off']") |> render_click()

      html =
        view
        |> form("#time-off-form-modal-form", %{
          "starts_on" => "2027-07-05",
          "ends_on" => "2027-07-06"
        })
        |> render_change()

      assert html =~ "Night call"
      assert html =~ ~r/Monday 5 July, 12:30 AM\s*<\/span><span class="font-medium">Night call/
    end
  end

  defp booking(user, start_time, title) do
    insert(:meeting,
      organizer_user_id: user.id,
      title: title,
      start_time: start_time,
      end_time: DateTime.add(start_time, 30, :minute)
    )
  end
end
