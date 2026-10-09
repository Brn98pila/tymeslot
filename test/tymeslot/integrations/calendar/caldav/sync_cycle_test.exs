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

  test "a server that does not answer is the cycle's outcome", %{integration: integration} do
    ReqTest.stub(:tymeslot_http, &ReqTest.transport_error(&1, :timeout))

    assert {:error, reason} = CalDAVSync.run(integration, true)
    assert reason in [:timeout, :server_unresponsive, :network_error]
    assert cached_uids(integration) == []
  end
end
