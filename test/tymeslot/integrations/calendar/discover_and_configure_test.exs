defmodule Tymeslot.Integrations.Calendar.DiscoverAndConfigureTest do
  use Tymeslot.DataCase, async: true

  @moduletag :calendar
  @moduletag :integrations

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Integrations.CalendarPrimary

  setup :verify_on_exit!

  setup do
    %{user: insert(:user)}
  end

  describe "discover_and_configure_calendars/1 after an OAuth connection" do
    test "a Google calendar's id never lands in the CalDAV path list", %{user: user} do
      expect(GoogleCalendarAPIMock, :list_calendars, fn _integration ->
        {:ok, [%{"id" => "primary", "summary" => "Primary", "primary" => true}]}
      end)

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          calendar_paths: [],
          calendar_list: []
        )

      assert {:ok, updated} = CalendarPrimary.discover_and_configure_calendars(integration)

      assert updated.calendar_paths == []
      assert [%{id: "primary"}] = updated.calendar_list
    end

    test "a read-only calendar listed first is passed over for the writable one",
         %{user: user} do
      # Delegated or Workspace resource accounts can have no primary entry at
      # all, so the choice falls through to the first calendar listed.
      expect(GoogleCalendarAPIMock, :list_calendars, fn _integration ->
        {:ok,
         [
           %{"id" => "holidays", "summary" => "Holidays", "accessRole" => "reader"},
           %{"id" => "writable", "summary" => "Writable", "accessRole" => "owner"}
         ]}
      end)

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          calendar_paths: [],
          calendar_list: []
        )

      assert {:ok, updated} = CalendarPrimary.discover_and_configure_calendars(integration)

      assert updated.default_booking_calendar_id == "writable"
    end
  end
end
