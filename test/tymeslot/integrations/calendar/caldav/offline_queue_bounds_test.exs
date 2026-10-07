defmodule Tymeslot.Integrations.Calendar.CalDAV.OfflineQueueBoundsTest do
  @moduledoc """
  Covers the bounds on one offline queue flush: where it stops, how many rows
  it replays, and which rows it no longer replays.
  """

  use Tymeslot.DataCase, async: false

  import Tymeslot.ConfigTestHelpers

  @moduletag :integrations
  @moduletag :calendar

  alias Ecto.Adapters.SQL
  alias Plug.Conn
  alias Req.Test, as: ReqTest
  alias Tymeslot.Integrations.Calendar.CalDAV.OfflineQueue
  alias Tymeslot.Repo

  @client %{
    base_url: "https://caldav.example.com",
    username: "user",
    password: "pass",
    calendar_paths: ["/cal/"],
    verify_ssl: true,
    provider: :caldav
  }

  defp insert_pending_row(integration, attrs) do
    defaults = %{
      calendar_integration: integration,
      uid: "queue-event-uid",
      provider: "caldav",
      provider_calendar_id: "/cal/",
      provider_event_id: "/cal/queue-event-uid.ics",
      summary: "Queued",
      start_at: ~U[2026-04-15 14:00:00.000000Z],
      end_at: ~U[2026-04-15 15:00:00.000000Z],
      all_day: false,
      timezone: "UTC",
      synced_at: ~U[2026-04-15 00:00:00.000000Z],
      etag: "\"cached-etag\""
    }

    insert(:provider_calendar_event, Map.merge(defaults, Map.new(attrs)))
  end

  setup do
    with_config(:tymeslot, :http_client_module, Tymeslot.Infrastructure.HTTPClient)

    integration =
      insert(:calendar_integration,
        provider: "caldav",
        calendar_paths: ["/cal/"]
      )

    {:ok, integration: integration}
  end

  # One stuck server, or one change it will never accept, must not hold the
  # sync job: each row could otherwise wait out its own write timeout.
  describe "flush/2 — bounds" do
    defp count_requests(status) do
      counter = :counters.new(1, [])

      ReqTest.stub(:tymeslot_http, fn conn ->
        :counters.add(counter, 1, 1)
        Conn.send_resp(conn, status, "")
      end)

      counter
    end

    test "stops at the first failure that says the server is unreachable",
         %{integration: integration} do
      first =
        insert_pending_row(integration,
          uid: "first",
          provider_event_id: "/cal/first.ics",
          sync_state: "locally_modified"
        )

      second =
        insert_pending_row(integration,
          uid: "second",
          provider_event_id: "/cal/second.ics",
          sync_state: "locally_modified"
        )

      SQL.query!(Repo, "UPDATE provider_calendar_events SET updated_at = $1 WHERE id = $2", [
        ~U[2026-04-14 00:00:00.000000Z],
        first.id
      ])

      test_pid = self()

      ReqTest.stub(:tymeslot_http, fn conn ->
        send(test_pid, {:put, conn.request_path})
        Conn.send_resp(conn, 502, "")
      end)

      assert :ok = OfflineQueue.flush(integration, @client)

      assert_received {:put, "/cal/first.ics"}
      refute_received {:put, "/cal/second.ics"}
      assert Repo.reload!(first).sync_attempts == 1
      assert Repo.reload!(second).sync_attempts == 0
    end

    test "carries on past a change the server refuses", %{integration: integration} do
      insert_pending_row(integration, uid: "first", sync_state: "locally_modified")
      insert_pending_row(integration, uid: "second", sync_state: "locally_modified")

      counter = count_requests(403)

      assert :ok = OfflineQueue.flush(integration, @client)
      assert :counters.get(counter, 1) == 2
    end

    test "replays at most 50 rows in one flush", %{integration: integration} do
      for n <- 1..51 do
        insert_pending_row(integration, uid: "row-#{n}", sync_state: "locally_modified")
      end

      counter = count_requests(204)

      assert :ok = OfflineQueue.flush(integration, @client)
      assert :counters.get(counter, 1) == 50
    end

    test "no longer replays a row that has failed ten times", %{integration: integration} do
      spent =
        insert_pending_row(integration,
          uid: "spent",
          sync_state: "locally_modified",
          sync_attempts: 10,
          sync_last_error: "The calendar server refused the change."
        )

      counter = count_requests(204)

      assert :ok = OfflineQueue.flush(integration, @client)

      assert :counters.get(counter, 1) == 0
      reloaded = Repo.reload!(spent)
      assert reloaded.sync_state == "locally_modified"
      assert reloaded.sync_last_error == "The calendar server refused the change."
    end
  end
end
