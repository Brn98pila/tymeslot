defmodule Tymeslot.Integrations.Calendar.SeriesRulesTest do
  @moduledoc """
  The stored rules of Google and Outlook series, as the cache writes see
  them: copied onto each occurrence an upsert caches, and forgotten once the
  cache holds no occurrence of their series.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :calendar
  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Calendar.SeriesRuleQueries
  alias Tymeslot.Integrations.Calendar.Sync

  setup do
    %{integration: insert(:calendar_integration, provider: "outlook")}
  end

  describe "an upsert of occurrences" do
    test "gives each occurrence its series' stored rule", %{integration: integration} do
      put_rule(integration, "master-1", "FREQ=WEEKLY;BYDAY=MO")

      assert {:ok, 2} =
               Sync.upsert_cache(integration, [
                 occurrence(integration, "occ-1", "master-1"),
                 occurrence(integration, "occ-2", nil)
               ])

      assert rule_of(integration, "occ-1") == "FREQ=WEEKLY;BYDAY=MO"
      assert rule_of(integration, "occ-2") == nil
    end

    test "leaves an occurrence of a series with no stored rule without one", %{
      integration: integration
    } do
      assert {:ok, 1} =
               Sync.upsert_cache(integration, [occurrence(integration, "occ-1", "master-1")])

      assert rule_of(integration, "occ-1") == nil
    end

    # The upsert replaces a row's rule with what the event carries, and the
    # provider's events carry none.
    test "keeps the rule when the occurrence is cached again", %{integration: integration} do
      put_rule(integration, "master-1", "FREQ=WEEKLY;BYDAY=MO")
      event = occurrence(integration, "occ-1", "master-1")

      {:ok, 1} = Sync.upsert_cache(integration, [event])
      {:ok, 1} = Sync.upsert_cache(integration, [%{event | summary: "Renamed"}])

      assert rule_of(integration, "occ-1") == "FREQ=WEEKLY;BYDAY=MO"
    end

    test "keeps a rule the event carries of its own", %{integration: integration} do
      put_rule(integration, "master-1", "FREQ=WEEKLY;BYDAY=MO")

      event = %{occurrence(integration, "occ-1", "master-1") | recurrence_rule: "FREQ=DAILY"}
      {:ok, 1} = Sync.upsert_cache(integration, [event])

      assert rule_of(integration, "occ-1") == "FREQ=DAILY"
    end

    test "reads another integration's rule for nothing", %{integration: integration} do
      other = insert(:calendar_integration, provider: "outlook")
      put_rule(other, "master-1", "FREQ=WEEKLY;BYDAY=MO")

      {:ok, 1} = Sync.upsert_cache(integration, [occurrence(integration, "occ-1", "master-1")])

      assert rule_of(integration, "occ-1") == nil
    end
  end

  describe "a deletion of occurrences" do
    test "forgets the rule of a series with none left, and keeps the others", %{
      integration: integration
    } do
      put_rule(integration, "master-1", "FREQ=WEEKLY;BYDAY=MO")
      put_rule(integration, "master-2", "FREQ=DAILY")

      {:ok, 2} =
        Sync.upsert_cache(integration, [
          occurrence(integration, "occ-1", "master-1"),
          occurrence(integration, "occ-2", "master-2")
        ])

      :ok = Sync.reconcile_deletions(integration, [%{provider_event_id: "occ-1", uid: "occ-1"}])

      assert SeriesRuleQueries.get(integration.id, "master-1") == nil
      assert %{rule: "FREQ=DAILY"} = SeriesRuleQueries.get(integration.id, "master-2")
    end
  end

  defp put_rule(integration, master_id, rule) do
    {:ok, _row} =
      SeriesRuleQueries.put(integration.id, master_id, %{
        rule: rule,
        master_start: ~U[2026-10-05 07:00:00Z],
        fetched_at: DateTime.utc_now(:second)
      })
  end

  defp occurrence(integration, id, master_id) do
    CalendarEvent.new!(%{
      uid: id,
      calendar_integration_id: integration.id,
      provider: :outlook,
      provider_calendar_id: "calendar-1",
      provider_event_id: id,
      recurring_event_id: master_id,
      summary: "Weekly standup",
      all_day: false,
      start_at: ~U[2026-10-19 07:00:00Z],
      end_at: ~U[2026-10-19 07:30:00Z],
      synced_at: DateTime.utc_now()
    })
  end

  defp rule_of(integration, uid) do
    {:ok, row} = ProviderCalendarEventQueries.get_by_uid(integration.id, uid)
    row.recurrence_rule
  end
end
