defmodule TymeslotWeb.Dashboard.CalendarGrid.VisibleWindowLiveViewTest do
  @moduledoc """
  The grid shows every event on the days it displays, as the viewer's zone
  reads them, and nothing from the days either side: a host west of UTC sees
  their late evening on the last visible day, a host east of UTC sees their
  early morning on the first.

  Each test freezes the clock the grid reads, so the visible period is fixed
  rather than whichever week the suite happens to run in.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory
  import Tymeslot.Test.ClockHelpers

  alias Plug.Test

  # A Sunday that ends a month: the week shown is Monday 22 to Sunday 28
  # February, and the agenda runs from the 28th to 30 March.
  @sunday ~D[2027-02-28]

  defp sign_in(conn, timezone) do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    insert(:profile, user: user, timezone: timezone)
    integration = insert(:calendar_integration, user: user, is_active: true)
    conn = conn |> Test.init_test_session(%{}) |> fetch_session() |> log_in_user(user)
    {conn, integration}
  end

  defp freeze_at(date, time, timezone), do: freeze_clock(local(date, time, timezone))

  defp local(date, time, timezone),
    do: date |> DateTime.new!(time, timezone) |> DateTime.shift_zone!("Etc/UTC")

  defp insert_event(integration, date, time, timezone) do
    start_at = local(date, time, timezone)

    insert(:provider_calendar_event,
      calendar_integration: integration,
      summary: "Late call",
      start_at: start_at,
      end_at: DateTime.add(start_at, 30, :minute),
      all_day: false,
      recurrence_rule: nil,
      recurring_event_id: nil,
      sync_state: "synced"
    )
  end

  defp on_grid?(lv, event), do: has_element?(lv, "[id^='event-#{event.id}-']")

  describe "a frozen clock" do
    test "is the one the mounted grid opens on", %{conn: conn} do
      {conn, _integration} = sign_in(conn, "America/New_York")
      freeze_at(@sunday, ~T[17:00:00], "America/New_York")

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      assert has_element?(lv, "[data-day-col='2027-02-22']")
      assert has_element?(lv, "#current-time-2027-02-28")
    end
  end

  describe "a host west of UTC" do
    setup %{conn: conn} do
      {conn, integration} = sign_in(conn, "America/New_York")
      freeze_at(@sunday, ~T[17:00:00], "America/New_York")
      {:ok, conn: conn, integration: integration}
    end

    test "sees an evening event on the last day of the week", %{conn: conn, integration: i} do
      # 22:00 in New York is 03:00 UTC on 1 March, after the week's last UTC day.
      event = insert_event(i, @sunday, ~T[22:00:00], "America/New_York")

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      assert on_grid?(lv, event)
    end

    test "does not see the days either side of the week", %{conn: conn, integration: i} do
      after_week = insert_event(i, ~D[2027-03-01], ~T[00:30:00], "America/New_York")
      before_week = insert_event(i, ~D[2027-02-21], ~T[23:30:00], "America/New_York")

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      assert has_element?(lv, "[data-day-col='2027-02-28']")
      refute on_grid?(lv, after_week)
      refute on_grid?(lv, before_week)
    end

    test "sees an evening event on the agenda's last day, and not the day after", %{
      conn: conn,
      integration: i
    } do
      last_day = Date.add(@sunday, 30)
      on_last_day = insert_event(i, last_day, ~T[22:00:00], "America/New_York")
      day_after = insert_event(i, Date.add(last_day, 1), ~T[00:30:00], "America/New_York")

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("#calendar-grid") |> render_hook("set_view", %{"view" => "agenda"})

      assert has_element?(lv, "#agenda-event-#{on_last_day.id}-#{Date.to_iso8601(last_day)}")
      refute has_element?(lv, "[id^='agenda-event-#{day_after.id}-']")
    end
  end

  describe "a host east of UTC" do
    setup %{conn: conn} do
      {conn, integration} = sign_in(conn, "Asia/Tokyo")
      freeze_at(~D[2027-02-24], ~T[12:00:00], "Asia/Tokyo")
      {:ok, conn: conn, integration: integration}
    end

    test "sees an early event on the first day of the week, and not the night before", %{
      conn: conn,
      integration: i
    } do
      # 00:30 on Monday in Tokyo is 15:30 UTC on the Sunday before.
      first_morning = insert_event(i, ~D[2027-02-22], ~T[00:30:00], "Asia/Tokyo")
      night_before = insert_event(i, ~D[2027-02-21], ~T[23:30:00], "Asia/Tokyo")

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      assert on_grid?(lv, first_morning)
      refute on_grid?(lv, night_before)
    end
  end
end
