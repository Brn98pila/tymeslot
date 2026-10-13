defmodule Tymeslot.Integrations.Calendar.SeriesRulesTest do
  @moduledoc """
  The stored rules of Google and Outlook series, as the cache writes see
  them: copied onto each occurrence an upsert caches, and forgotten once the
  cache holds no occurrence of their series.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :calendar
  @moduletag :integrations

  import ExUnit.CaptureLog

  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Calendar.SeriesRuleQueries
  alias Tymeslot.Integrations.Calendar.SeriesRules
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

  describe "refresh/3" do
    test "reads the masters the events name and stores what it found", %{
      integration: integration
    } do
      read = reader(%{"master-1" => {:ok, found("FREQ=WEEKLY;BYDAY=MO")}})

      assert :ok =
               SeriesRules.refresh(
                 integration.id,
                 [occurrence(integration, "occ-1", "master-1")],
                 read
               )

      assert_received {:read, "master-1"}

      assert %{rule: "FREQ=WEEKLY;BYDAY=MO", master_start: ~U[2026-10-05 07:00:00Z]} =
               SeriesRuleQueries.get(integration.id, "master-1")
    end

    test "reads a master a change names again however fresh its rule is", %{
      integration: integration
    } do
      put_rule(integration, "master-1", "FREQ=DAILY")
      read = reader(%{"master-1" => {:ok, found("FREQ=WEEKLY;BYDAY=MO")}})
      events = [occurrence(integration, "occ-1", "master-1")]

      SeriesRules.refresh(integration.id, events, read, changed: true)

      assert SeriesRuleQueries.get(integration.id, "master-1").rule == "FREQ=WEEKLY;BYDAY=MO"
    end

    # A listing says nothing changed: a sync run that lists a calendar every
    # time must not read every series it holds every time.
    test "reads no master a listing names while its rule is fresh", %{integration: integration} do
      put_rule(integration, "master-1", "FREQ=DAILY")
      read = reader(%{"master-1" => {:ok, found("FREQ=WEEKLY;BYDAY=MO")}})

      SeriesRules.refresh(integration.id, [occurrence(integration, "occ-1", "master-1")], read)

      assert received_reads() == []
    end

    # A sync cycle calls refresh once per batch it caches: the delta, the
    # series it relists, each other calendar.
    test "reads at most 50 masters across the calls of one cycle", %{integration: integration} do
      batch = fn range ->
        for n <- range, do: occurrence(integration, "occ-#{n}", "master-#{n}")
      end

      read = reader(Map.new(1..60, &{"master-#{&1}", {:ok, found("FREQ=DAILY")}}))

      SeriesRules.refresh(integration.id, batch.(1..30), read, changed: true)
      SeriesRules.refresh(integration.id, batch.(31..60), read, changed: true)

      assert length(received_reads()) == 50
    end

    # A series the cache already holds, whose occurrences did not change.
    test "reads a cached series' master once its rule is stale, and not before", %{
      integration: integration
    } do
      {:ok, 2} =
        Sync.upsert_cache(integration, [
          occurrence(integration, "occ-1", "stale-master"),
          occurrence(integration, "occ-2", "fresh-master")
        ])

      put_rule(integration, "fresh-master", "FREQ=DAILY")

      put_rule(
        integration,
        "stale-master",
        "FREQ=DAILY",
        DateTime.add(DateTime.utc_now(:second), -2, :day)
      )

      read =
        reader(%{
          "stale-master" => {:ok, found("FREQ=WEEKLY")},
          "fresh-master" => {:ok, found("FREQ=WEEKLY")}
        })

      SeriesRules.refresh(integration.id, [], read)

      assert_received {:read, "stale-master"}
      refute_received {:read, "fresh-master"}
    end

    test "reads at most 50 masters a run", %{integration: integration} do
      events = for n <- 1..60, do: occurrence(integration, "occ-#{n}", "master-#{n}")
      read = reader(Map.new(1..60, &{"master-#{&1}", {:ok, found("FREQ=DAILY")}}))

      SeriesRules.refresh(integration.id, events, read)

      assert length(received_reads()) == 50
    end

    test "records a master that is gone, so that it is not asked about again at once", %{
      integration: integration
    } do
      read = reader(%{"master-1" => :gone})

      SeriesRules.refresh(integration.id, [occurrence(integration, "occ-1", "master-1")], read)
      assert_received {:read, "master-1"}
      {:ok, 1} = Sync.upsert_cache(integration, [occurrence(integration, "occ-1", "master-1")])

      assert %{rule: nil} = SeriesRuleQueries.get(integration.id, "master-1")
      assert rule_of(integration, "occ-1") == nil

      SeriesRules.refresh(integration.id, [], read)
      refute_received {:read, "master-1"}
    end

    # Graph and Google ids run past 255 bytes.
    test "stores the rule of a master whose id is longer than 255 bytes", %{
      integration: integration
    } do
      master_id = String.duplicate("A", 300)
      read = reader(%{master_id => {:ok, found("FREQ=DAILY")}})

      SeriesRules.refresh(integration.id, [occurrence(integration, "occ-1", master_id)], read)

      assert SeriesRuleQueries.get(integration.id, master_id).rule == "FREQ=DAILY"
    end

    test "skips a read it cannot store and goes on to the next", %{integration: integration} do
      read =
        reader(%{
          "master-1" => {:ok, %{rule: 123, master_start: nil}},
          "master-2" => {:ok, found("FREQ=DAILY")}
        })

      events = [
        occurrence(integration, "occ-1", "master-1"),
        occurrence(integration, "occ-2", "master-2")
      ]

      log = capture_log(fn -> assert :ok = SeriesRules.refresh(integration.id, events, read) end)

      assert log =~ "could not be stored"
      assert SeriesRuleQueries.get(integration.id, "master-1") == nil
      assert SeriesRuleQueries.get(integration.id, "master-2").rule == "FREQ=DAILY"
    end

    # Throttled, refused or unreachable: every later read would fail alike.
    test "stops reading at the first read that says to stop", %{integration: integration} do
      read =
        reader(%{
          "master-1" => {:stop, :rate_limited},
          "master-2" => {:ok, found("FREQ=DAILY")}
        })

      events = [
        occurrence(integration, "occ-1", "master-1"),
        occurrence(integration, "occ-2", "master-2")
      ]

      assert :ok = SeriesRules.refresh(integration.id, events, read)

      assert received_reads() == ["master-1"]
      assert SeriesRuleQueries.get(integration.id, "master-2") == nil
    end
  end

  describe "with_series_start/1" do
    test "gives an occurrence its series' first start, and nothing else", %{
      integration: integration
    } do
      put_rule(integration, "master-1", "FREQ=WEEKLY;COUNT=5")

      [stamped, single, unknown] =
        SeriesRules.with_series_start([
          %{calendar_integration_id: integration.id, recurring_event_id: "master-1"},
          %{calendar_integration_id: integration.id, recurring_event_id: nil},
          %{calendar_integration_id: nil, recurring_event_id: "master-1"}
        ])

      assert stamped.series_start == ~U[2026-10-05 07:00:00Z]
      refute Map.has_key?(single, :series_start)
      refute Map.has_key?(unknown, :series_start)
    end
  end

  defp put_rule(integration, master_id, rule, fetched_at \\ DateTime.utc_now(:second)) do
    {:ok, _row} =
      SeriesRuleQueries.put(integration.id, master_id, %{
        rule: rule,
        master_start: ~U[2026-10-05 07:00:00Z],
        fetched_at: fetched_at
      })
  end

  defp found(rule), do: %{rule: rule, master_start: ~U[2026-10-05 07:00:00Z]}

  # Answers each master as `answers` says, and reports each read.
  defp reader(answers) do
    test_pid = self()

    fn master_id, _calendar_id ->
      send(test_pid, {:read, master_id})
      Map.fetch!(answers, master_id)
    end
  end

  defp received_reads do
    receive do
      {:read, master_id} -> [master_id | received_reads()]
    after
      0 -> []
    end
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
