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

    test "Google's generated calendars are shown only; the owner's and shared ones block",
         %{user: user} do
      expect(GoogleCalendarAPIMock, :list_calendars, fn _integration ->
        {:ok,
         [
           %{"id" => "me@example.com", "summary" => "Me", "primary" => true},
           %{"id" => "team@group.calendar.google.com", "accessRole" => "reader"},
           %{"id" => "en.uk#holiday@group.v.calendar.google.com", "accessRole" => "reader"},
           %{
             "id" => "addressbook#contacts@group.v.calendar.google.com",
             "accessRole" => "reader"
           },
           %{"id" => "e_2_en#weeknum@group.v.calendar.google.com", "accessRole" => "reader"}
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

      assert Map.new(updated.calendar_list, &{&1.id, &1.blocks_availability}) == %{
               "me@example.com" => true,
               "team@group.calendar.google.com" => true,
               "en.uk#holiday@group.v.calendar.google.com" => false,
               "addressbook#contacts@group.v.calendar.google.com" => false,
               "e_2_en#weeknum@group.v.calendar.google.com" => false
             }
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
