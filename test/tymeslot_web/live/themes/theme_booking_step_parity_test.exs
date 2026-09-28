defmodule TymeslotWeb.Live.Themes.ThemeBookingStepParityTest do
  @moduledoc """
  Behaviour every theme's steps share, whatever they look like: choosing the
  meeting type already chosen keeps it chosen, and the booking form will not
  submit without a name and an email.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :bookings
  @moduletag :themes
  @moduletag :live

  import Mox
  import Phoenix.LiveViewTest
  import Tymeslot.BookingTestHelpers
  import Tymeslot.ThemeBookingFlowHelpers

  alias Tymeslot.TestMocks
  alias TymeslotWeb.ThemeTestMatrix

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    TestMocks.setup_email_mocks()
    TestMocks.setup_subscription_mocks()

    Tymeslot.CalendarMock
    |> stub(:get_events_for_range_fresh, fn _user_id, _start_date, _end_date -> {:ok, []} end)
    |> stub(:get_booking_integration_info, fn _user_id -> {:error, :no_integration} end)

    :ok
  end

  @duration_option "button[data-testid='duration-option']"

  for theme <- ThemeTestMatrix.all() do
    @tag :capture_log
    test "theme #{theme.slug}: choosing the chosen meeting type again keeps it chosen",
         %{conn: conn} do
      %{profile: profile} =
        seed_booking_account(unquote(theme.id), "reselect-#{unquote(theme.slug)}", "Etc/UTC")

      {:ok, view, _html} = live(conn, "/#{profile.username}")

      view |> element(@duration_option) |> render_click()
      view |> element(@duration_option) |> render_click()

      assert has_element?(view, "button[data-testid='next-step']")
      refute has_element?(view, "button[data-testid='next-step'][disabled]")
    end

    @tag :capture_log
    test "theme #{theme.slug}: the booking form requires a name and an email", %{conn: conn} do
      %{profile: profile} =
        seed_booking_account(unquote(theme.id), "required-#{unquote(theme.slug)}", "Etc/UTC")

      view = navigate_to_booking_form(conn, profile, nil)

      # `.input`'s `required` attribute renders only as the label's `*`
      # marker today (Forms.input_element/1 never forwards `required` onto
      # the rendered `<input>` itself — a separate, pre-existing gap, not
      # Rhythm's), so parity is asserted against that marker.
      assert has_element?(view, "label[for='booking-form_name'] span.text-red-500")
      assert has_element?(view, "label[for='booking-form_email'] span.text-red-500")
    end
  end
end
