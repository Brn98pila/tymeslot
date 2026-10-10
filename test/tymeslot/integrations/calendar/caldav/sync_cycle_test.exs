defmodule Tymeslot.Integrations.Calendar.CalDAV.SyncCycleTest do
  @moduledoc """
  One CalDAV sync cycle (`CalDAV.Sync.run/2`), run without Oban: what it
  caches, and the outcome a failed one hands its caller with nothing
  recorded against the integration.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :calendar
  @moduletag :integrations

  import Req.Test, only: [set_req_test_to_shared: 1]
  import Tymeslot.CalDAVSyncTestFixtures
  import Tymeslot.ConfigTestHelpers

  alias Plug.Conn
  alias Req.Test, as: ReqTest
  alias Tymeslot.Integrations.Calendar.CalDAV.Sync, as: CalDAVSync
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema

  setup :set_req_test_to_shared

  setup do
    with_config(:tymeslot, :http_client_module, Tymeslot.Infrastructure.HTTPClient)
    with_config(:tymeslot, :req_test_plug, {Req.Test, :tymeslot_http})

    inserted =
      insert(:calendar_integration,
        provider: "caldav",
        is_active: true,
        needs_reauth: false,
        sync_error: nil,
        caldav_sync_tier: 3,
        calendar_paths: [path1(), path2()]
      )

    {:ok, integration} = CalendarIntegrationQueries.get(inserted.id)
    %{integration: integration}
  end

  defp cached_uids(integration) do
    Repo.all(
      from e in ProviderCalendarEventSchema,
        where: e.calendar_integration_id == ^integration.id,
        select: e.uid,
        order_by: e.uid
    )
  end

  test "a full fetch caches every calendar path", %{integration: integration} do
    ReqTest.stub(:tymeslot_http, &respond_to_dual_paths/1)

    assert :ok = CalDAVSync.run(integration, true)
    assert cached_uids(integration) == ["event-from-path1@test", "event-from-path2@test"]
  end

  test "a refused credential is :unauthorized, with nothing recorded", %{
    integration: integration
  } do
    ReqTest.stub(:tymeslot_http, &Conn.send_resp(&1, 401, "Unauthorized"))

    assert {:error, :unauthorized} = CalDAVSync.run(integration, true)

    assert {:ok, %{needs_reauth: false, sync_error: nil}} =
             CalendarIntegrationQueries.get(integration.id)
  end

  describe "a calendar shared as busy times only" do
    # It answers calendar-query with 403; the sync must never ask it, or the
    # 403 reaches the reauth flag that reconnecting cannot clear.
    defp sharing(paths_and_flags) do
      inserted =
        insert(:calendar_integration,
          provider: "caldav",
          is_active: true,
          caldav_sync_tier: 3,
          calendar_paths: Enum.map(paths_and_flags, &elem(&1, 0)),
          calendar_list:
            for {path, free_busy_only?} <- paths_and_flags do
              %{id: path, path: path, selected: true, free_busy_only: free_busy_only?}
            end
        )

      {:ok, integration} = CalendarIntegrationQueries.get(inserted.id)
      integration
    end

    # Tells `test_pid` of every request for the shared path, and refuses it.
    defp refusing_free_busy_path(test_pid) do
      fn conn ->
        if conn.request_path == path2() do
          send(test_pid, {:asked, conn.request_path})
          Conn.send_resp(conn, 403, "Forbidden")
        else
          respond_to_dual_paths(conn)
        end
      end
    end

    test "is left out of the sync, the other calendars synced" do
      integration = sharing([{path1(), false}, {path2(), true}])
      ReqTest.stub(:tymeslot_http, refusing_free_busy_path(self()))

      assert :ok = CalDAVSync.run(integration, true)
      assert cached_uids(integration) == ["event-from-path1@test"]
      refute_received {:asked, _path}
    end

    test "alone leaves nothing to sync, and nothing to flag" do
      integration = sharing([{path2(), true}])
      ReqTest.stub(:tymeslot_http, refusing_free_busy_path(self()))

      assert :ok = CalDAVSync.run(integration, false)
      refute_received {:asked, _path}

      assert {:ok, %{needs_reauth: false, sync_error: nil}} =
               CalendarIntegrationQueries.get(integration.id)
    end
  end

  test "a server that does not answer is the cycle's outcome", %{integration: integration} do
    ReqTest.stub(:tymeslot_http, &ReqTest.transport_error(&1, :timeout))

    assert {:error, reason} = CalDAVSync.run(integration, true)
    assert reason in [:timeout, :server_unresponsive, :network_error]
    assert cached_uids(integration) == []
  end
end
