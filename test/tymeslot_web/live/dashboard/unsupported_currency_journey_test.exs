defmodule TymeslotWeb.Dashboard.UnsupportedCurrencyJourneyTest do
  @moduledoc """
  A host whose Connect account was opened before the currency allowlist was
  enforced, in a currency it does not hold (here Romanian lei). They can
  still edit and save meeting types; payments are off, and both the editor
  and the payments page say why; choosing a supported currency turns
  payments back on.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :payments
  @moduletag :meeting_types
  @moduletag :live

  import Phoenix.LiveViewTest
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.MeetingTypes

  @notice "is not supported for meeting payments"

  setup :setup_dashboard_user

  setup %{user: user} do
    with_config(:tymeslot,
      feature_access_checker: Tymeslot.Features.DefaultAccessChecker,
      meeting_payments_enabled: true
    )

    # Inserted directly: the changeset would refuse the currency now.
    insert(:connect_account,
      user: user,
      stripe_account_id: "acct_legacy_ron",
      default_currency: "ron",
      charges_enabled: true,
      payouts_enabled: true,
      details_submitted: true
    )

    :ok
  end

  test "the host keeps editing meeting types, is told why payments are off, and can fix it",
       %{conn: conn, user: user} do
    meeting_type = insert(:meeting_type, user: user, name: "Intro call")

    # The editor opens, with the payment toggle disabled and the reason.
    view = open_editor(conn, meeting_type)

    assert has_element?(view, "#meeting-type-form-tabs-panel-booking", @notice)
    assert render(view) =~ "RON"
    assert render(view) =~ ~r/<input[^>]*type="checkbox"[^>]*disabled/

    # A free meeting type still saves.
    view
    |> element("input[name='meeting_type[name]']")
    |> render_change(%{"meeting_type" => %{"name" => "Intro call, renamed"}})

    assert MeetingTypes.get_meeting_type(meeting_type.id, user.id).name == "Intro call, renamed"

    # The payments page says the same, above the currency picker.
    {:ok, payments, _html} = live(conn, ~p"/dashboard/integrations?tab=payments")
    assert render(payments) =~ @notice

    payments
    |> element("button[phx-click=change_currency][phx-value-currency=eur]")
    |> render_click()

    refute render(payments) =~ @notice

    # With a supported currency, the editor offers payments again.
    view = open_editor(conn, meeting_type)

    refute render(view) =~ @notice

    view
    |> element("input[phx-click='toggle_payment_required']")
    |> render_click()

    assert render(view) =~ "Price (EUR)"
  end

  defp open_editor(conn, meeting_type) do
    {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

    view
    |> element("button[phx-click='edit_type'][phx-value-id='#{meeting_type.id}']")
    |> render_click()

    view
  end
end
