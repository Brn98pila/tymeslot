defmodule TymeslotWeb.Live.Themes.IgnoredStepEventTest do
  @moduledoc """
  A step event nothing handles leaves one warning naming the theme, the step
  and the event, once per page view; a real booking through every theme
  leaves none, so the warning only ever means a template sends a name the
  flow does not know.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :bookings
  @moduletag :themes
  @moduletag :live

  import Mox
  import Phoenix.LiveViewTest
  import Tymeslot.ThemeBookingFlowHelpers

  alias Tymeslot.Test.LogCapture
  alias Tymeslot.TestMocks
  alias TymeslotWeb.ThemeTestMatrix

  @message "Booking step event ignored"

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    TestMocks.setup_email_mocks()
    TestMocks.setup_subscription_mocks()

    Tymeslot.CalendarMock
    |> stub(:get_events_for_range_fresh, fn _user_id, _start_date, _end_date -> {:ok, []} end)
    |> stub(:get_booking_integration_info, fn _user_id -> {:error, :no_integration} end)

    LogCapture.attach()
    :ok
  end

  for theme <- ThemeTestMatrix.all() do
    test "#{theme.name}: a canonical event on the wrong step is logged once", %{conn: conn} do
      %{profile: profile} =
        seed_booking_account(unquote(theme.id), "ignored-#{unquote(theme.slug)}", "Etc/UTC")

      {:ok, view, _html} = live(conn, "/#{profile.username}")

      # The overview is on screen; select_date belongs to the schedule step.
      send(view.pid, {:step_event, :overview, :select_date, "2030-01-01"})
      send(view.pid, {:step_event, :overview, :select_date, "2030-01-02"})
      assert render(view) =~ unquote(theme.wrapper_class)

      assert_receive {:captured_log, %{level: :warning, meta: %{event: "select_date"} = meta}}
      assert meta.theme_id == unquote(theme.id)
      assert meta.step == :overview
      refute_receive {:captured_log, %{meta: %{event: "select_date"}}}, 100
    end

    test "#{theme.name}: a whole booking logs no ignored step event", %{conn: conn} do
      %{profile: profile} =
        seed_booking_account(unquote(theme.id), "clean-#{unquote(theme.slug)}", "Etc/UTC")

      {:ok, view, _html} = live(conn, "/#{profile.username}")

      complete_booking_flow(view, unquote(theme.name), unquote(theme.id), %{
        name: "Ada Lovelace",
        email: "ada@example.com",
        message: "Hello"
      })

      ignored = Enum.filter(LogCapture.drain(), &(LogCapture.message_text(&1.msg) == @message))

      assert ignored == [], Enum.map_join(ignored, "\n", &LogCapture.dump/1)
    end
  end
end
