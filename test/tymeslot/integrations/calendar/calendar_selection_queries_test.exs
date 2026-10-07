defmodule Tymeslot.Integrations.Calendar.CalendarSelectionQueriesTest do
  use Tymeslot.DataCase, async: true
  @moduletag :integrations
  @moduletag :calendar

  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.CalendarSelectionQueries
  alias Tymeslot.Integrations.Calendar.Selection

  describe "deselect_calendars/2" do
    test "marks matching calendars as unselected and leaves others untouched" do
      integration =
        insert(:calendar_integration,
          provider: "google",
          calendar_list: [
            %{"id" => "primary", "selected" => true, "name" => "Primary"},
            %{"id" => "gone@example.com", "selected" => true, "name" => "Gone"}
          ]
        )

      {:ok, updated} =
        CalendarSelectionQueries.deselect_calendars(integration, ["gone@example.com"])

      assert Enum.find(updated.calendar_list, &(&1.id == "gone@example.com")).selected ==
               false

      assert Enum.find(updated.calendar_list, &(&1.id == "primary")).selected == true
    end

    test "is a no-op that persists unchanged when no ids match" do
      integration =
        insert(:calendar_integration,
          provider: "google",
          calendar_list: [%{"id" => "primary", "selected" => true, "name" => "Primary"}]
        )

      {:ok, updated} =
        CalendarSelectionQueries.deselect_calendars(integration, ["nonexistent@example.com"])

      assert updated.calendar_list == integration.calendar_list
    end

    # An availability read deselects from the struct it started with; a
    # selection the owner saved since must survive it.
    test "keeps a selection saved after the caller's struct was read" do
      integration =
        insert(:calendar_integration,
          provider: "google",
          calendar_list: [
            %{"id" => "work", "selected" => false, "name" => "Work"},
            %{"id" => "gone@example.com", "selected" => true, "name" => "Gone"}
          ]
        )

      {:ok, fresh} = CalendarIntegrationQueries.get(integration.id)

      {:ok, _saved} =
        Selection.update_calendar_selection(fresh, %{
          "selected_calendars" => ["work", "gone@example.com"]
        })

      {:ok, updated} =
        CalendarSelectionQueries.deselect_calendars(integration, ["gone@example.com"])

      assert Enum.find(updated.calendar_list, &(&1.id == "work")).selected == true
      assert Enum.find(updated.calendar_list, &(&1.id == "gone@example.com")).selected == false
    end
  end
end
