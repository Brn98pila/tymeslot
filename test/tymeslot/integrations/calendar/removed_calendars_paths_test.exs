defmodule Tymeslot.Integrations.Calendar.RemovedCalendarsPathsTest do
  @moduledoc """
  Every path that deselects a calendar the server stopped listing (an event
  read answered 404, a CalDAV sync, a Google sync, and discovery) records it
  on the integration and schedules the one email about it, and none of them
  deselects anything on a failed read or an empty answer.
  """
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :integrations
  @moduletag :integration

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Integrations.Calendar.CalDAV.Sync.EventFetch
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.Google.SyncCycle
  alias Tymeslot.Integrations.Calendar.Orchestration.Workflows
  alias Tymeslot.Integrations.Calendar.Shared.MultiCalendarFetch
  alias Tymeslot.Repo
  alias Tymeslot.Workers.EmailWorker

  @moduletag :capture_log

  setup :verify_on_exit!

  defp google(calendar_list) do
    inserted =
      insert(:calendar_integration,
        provider: "google",
        google_sync_token: "valid-token",
        default_booking_calendar_id: "primary",
        needs_reauth: false,
        calendar_list: calendar_list
      )

    {:ok, loaded} = CalendarIntegrationQueries.get(inserted.id)
    loaded
  end

  defp primary_and_work do
    google([
      %{"id" => "primary", "selected" => true, "name" => "Primary"},
      %{"id" => "work", "selected" => true, "name" => "Work"}
    ])
  end

  defp reload(integration), do: Repo.get!(CalendarIntegrationSchema, integration.id)

  defp recorded(integration),
    do: integration |> reload() |> Map.fetch!(:removed_calendars) |> Enum.map(& &1.id)

  defp selected?(integration, id),
    do:
      integration
      |> reload()
      |> Map.fetch!(:calendar_list)
      |> Enum.any?(&(&1.id == id and &1.selected))

  defp emailed, do: Enum.map(all_enqueued(worker: EmailWorker), & &1.args["calendar_names"])

  defp assert_untouched(integration, id) do
    assert selected?(integration, id)
    assert recorded(integration) == []
    assert emailed() == []
  end

  describe "an event read" do
    defp read_events(integration) do
      now = DateTime.utc_now()

      MultiCalendarFetch.list_events_with_selection(
        integration,
        now,
        DateTime.add(now, 7, :day),
        GoogleCalendarAPIMock
      )
    end

    test "records a calendar answered 404 and emails about it once, however often it is read" do
      integration = primary_and_work()

      stub(GoogleCalendarAPIMock, :list_events, fn
        _integration, "primary", _start, _end -> {:ok, []}
        _integration, "work", _start, _end -> {:error, :not_found, "Not Found"}
      end)

      # Both reads start from the same struct, as two availability checks
      # begun before either deselected anything do.
      assert {:ok, []} = read_events(integration)
      assert {:ok, []} = read_events(integration)

      refute selected?(integration, "work")
      assert recorded(integration) == ["work"]
      assert emailed() == [["Work"]]
    end

    test "deselects nothing when a read fails" do
      integration = primary_and_work()

      stub(GoogleCalendarAPIMock, :list_events, fn
        _integration, "primary", _start, _end -> {:ok, []}
        _integration, "work", _start, _end -> {:error, :server_error, "Internal Server Error"}
      end)

      assert {:error, _outcome} = read_events(integration)
      assert_untouched(integration, "work")
    end
  end

  describe "a CalDAV sync" do
    setup do
      integration =
        insert(:calendar_integration,
          provider: "caldav",
          default_booking_calendar_id: "/dav/home/",
          calendar_paths: ["/dav/home/", "/dav/team/"],
          calendar_list: [
            %{"id" => "/dav/home/", "path" => "/dav/home/", "selected" => true, "name" => "Home"},
            %{"id" => "/dav/team/", "path" => "/dav/team/", "selected" => true, "name" => "Team"}
          ]
        )

      %{integration: integration}
    end

    defp sync_paths(integration, client, team_answer) do
      EventFetch.each_path(integration, client, fn
        "/dav/team/" -> team_answer
        _path -> :ok
      end)
    end

    test "records a collection answered 404 and emails about it", %{integration: integration} do
      assert :ok = sync_paths(integration, integration, :not_found)

      assert reload(integration).calendar_paths == ["/dav/home/"]
      refute selected?(integration, "/dav/team/")
      assert recorded(integration) == ["/dav/team/"]
      assert emailed() == [["Team"]]
    end

    test "deselects nothing when a collection's read fails", %{integration: integration} do
      assert {:error, :timeout} = sync_paths(integration, integration, {:error, :timeout})
      assert_untouched(integration, "/dav/team/")
    end

    test "deselects nothing when there are no paths to read", %{integration: integration} do
      assert {:error, :no_calendar_paths} =
               sync_paths(integration, %{calendar_paths: []}, :not_found)

      assert_untouched(integration, "/dav/team/")
    end
  end

  describe "a Google sync" do
    setup do
      expect(GoogleCalendarAPIMock, :list_events_incremental, fn _integration ->
        {:ok, %{events: [], next_sync_token: "next-token"}}
      end)

      %{integration: primary_and_work()}
    end

    test "records a calendar answered 404 and emails about it", %{integration: integration} do
      expect(GoogleCalendarAPIMock, :list_events, fn _integration, "work", _start, _end ->
        {:error, :not_found, "Not Found"}
      end)

      assert :ok = SyncCycle.run(integration)

      refute selected?(integration, "work")
      assert recorded(integration) == ["work"]
      assert emailed() == [["Work"]]
    end

    test "deselects nothing when a read fails", %{integration: integration} do
      expect(GoogleCalendarAPIMock, :list_events, fn _integration, "work", _start, _end ->
        {:error, :server_error, "Internal Server Error"}
      end)

      assert {:error, _reason} = SyncCycle.run(integration)
      assert_untouched(integration, "work")
    end
  end

  describe "discovery" do
    setup do
      integration =
        google([
          %{"id" => "primary", "selected" => true, "name" => "Primary"},
          %{"id" => "work", "selected" => true, "name" => "Work"},
          %{"id" => "old", "selected" => false, "name" => "Old"}
        ])

      %{integration: integration}
    end

    defp discover(integration, answer) do
      expect(GoogleCalendarAPIMock, :list_calendars, fn _client -> answer end)
      Workflows.update_integration_with_discovery(integration)
    end

    test "records a selected calendar it no longer returns and emails about it", %{
      integration: integration
    } do
      assert {:ok, _updated} =
               discover(integration, {:ok, [%{"id" => "primary", "summary" => "Primary"}]})

      refute Enum.any?(reload(integration).calendar_list, &(&1.id == "work"))
      # `old` went too, but the owner had already stopped using it.
      assert recorded(integration) == ["work"]
      assert emailed() == [["Work"]]
    end

    test "deselects nothing when discovery fails", %{integration: integration} do
      assert {:error, _reason} = discover(integration, {:error, :server_error, "Server Error"})
      assert_untouched(integration, "work")
    end

    test "deselects nothing when discovery returns no calendars", %{integration: integration} do
      assert {:ok, _updated} = discover(integration, {:ok, []})
      assert_untouched(integration, "work")
    end
  end

  test "a calendar its owner deselects is not recorded or emailed about" do
    integration = primary_and_work()

    assert {:ok, _updated} =
             Calendar.toggle_calendar_selection(integration.user_id, integration.id, "work")

    refute selected?(integration, "work")
    assert recorded(integration) == []
    assert emailed() == []
  end
end
