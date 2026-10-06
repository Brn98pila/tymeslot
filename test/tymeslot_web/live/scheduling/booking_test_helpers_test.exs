defmodule Tymeslot.BookingTestHelpersTest do
  @moduledoc """
  `BookingTestHelpers.walk_to_booking_form/2`, which `navigate_to_booking_form/3,4`
  and a dozen flow suites start from, on every registered theme's picker: it
  reaches the booking form with tomorrow's first free time whatever the
  picker (a month of days, a week of days, the shared week grid), since it
  walks through `TymeslotWeb.BookingDriver`.
  """
  use TymeslotWeb.LiveCase, async: false

  @moduletag :scheduling
  @moduletag :integration

  import Mox

  import Tymeslot.BookingTestHelpers,
    only: [seed_booking_account: 3, walk_to_booking_form: 2]

  alias Tymeslot.CalendarMock
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.TestMocks
  alias TymeslotWeb.ThemeTestMatrix

  @timezone "Etc/UTC"

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    AvailabilityCache.clear_all()
    TestMocks.setup_all_mocks()

    CalendarMock
    |> stub(:get_events_for_range_fresh, fn _user_id, _start, _end -> {:ok, []} end)
    |> stub(:get_booking_integration_info, fn _user_id -> {:error, :no_integration} end)

    :ok
  end

  for theme <- ThemeTestMatrix.registered() do
    @tag :capture_log
    test "#{theme.name}: walk_to_booking_form/2 reaches the form with tomorrow's first time",
         %{conn: conn} do
      %{profile: profile} =
        seed_booking_account(unquote(theme.id), "walk-#{unquote(theme.slug)}", @timezone)

      {:ok, view, _html} = live(conn, "/#{profile.username}?timezone=#{@timezone}")

      walk_to_booking_form(view, @timezone)

      assert has_element?(view, "form[data-fact='attendee']")

      assert live_assigns(view).selected_date ==
               Date.utc_today() |> Date.add(1) |> Date.to_iso8601()
    end
  end

  defp live_assigns(view), do: :sys.get_state(view.pid).socket.assigns
end
