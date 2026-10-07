defmodule Tymeslot.Integrations.Calendar.TokensConcurrencyTest do
  @moduledoc """
  Concurrency tests for OAuth token refresh operations.

  ## Note on Process.sleep Usage

  This test file intentionally uses `Process.sleep/1` in mocks to simulate
  slow external API calls and test race condition handling. These sleeps are
  necessary to:

  1. Create realistic timing scenarios where multiple refresh attempts overlap
  2. Verify that the locking mechanism prevents concurrent refreshes
  3. Test that the second attempt properly detects an in-progress refresh

  The sleeps are part of the test design to verify concurrent behavior, not
  timing dependencies that should be replaced with `eventually/2`.
  """

  # async: false to avoid ETS table issues if not careful
  use Tymeslot.DataCase, async: false
  @moduletag :integrations

  import Mox
  import Tymeslot.Factory
  alias Ecto.Changeset
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.Shared.AccessToken
  alias Tymeslot.Integrations.Calendar.Tokens
  alias Tymeslot.Integrations.Shared.Lock
  alias Tymeslot.Repo

  setup :verify_on_exit!

  describe "refresh_oauth_token concurrency" do
    test "only allows one refresh at a time for the same integration" do
      # We'll use a shared integration ID
      integration_id = 999_888

      integration = %{
        id: integration_id,
        provider: "google",
        access_token: "old_token",
        refresh_token: "refresh_token",
        token_expires_at: DateTime.add(DateTime.utc_now(), -3600, :second)
      }

      # Setup mock to block briefly to simulate work
      test_pid = self()

      expect(GoogleCalendarAPIMock, :refresh_token, 1, fn _int ->
        # Send message to parent to signal we started
        send(test_pid, :refresh_started)

        # Intentional sleep: Simulate slow external API call to create
        # a window where concurrent refresh attempts can occur, testing
        # that the second attempt properly detects :refresh_in_progress
        Process.sleep(100)

        {:ok, {"new_access", "new_refresh", DateTime.add(DateTime.utc_now(), 3600)}}
      end)

      # Start first refresh in a task
      task1 = Task.async(fn -> Tokens.refresh_oauth_token(integration) end)

      # Wait for first refresh to start
      assert_receive :refresh_started, 500

      # Try second refresh immediately - should fail with :refresh_in_progress
      assert {:error, :refresh_in_progress} = Tokens.refresh_oauth_token(integration)

      # Wait for first refresh to finish
      assert {:ok, updated} = Task.await(task1)
      assert updated.access_token == "new_access"
    end

    test "takes over a lock whose holder has died" do
      integration_id = 777_666

      {dead_pid, ref} = spawn_monitor(fn -> :ok end)
      assert_receive {:DOWN, ^ref, :process, ^dead_pid, _reason}

      old_now = System.monotonic_time(:millisecond) - 3_600_000
      Lock.put_lock(Tokens.refresh_lock_key(integration_id), old_now, dead_pid)

      integration = %{
        id: integration_id,
        provider: "google",
        access_token: "old_token",
        refresh_token: "refresh_token",
        token_expires_at: DateTime.add(DateTime.utc_now(), -3600, :second)
      }

      expect(GoogleCalendarAPIMock, :refresh_token, 1, fn _int ->
        {:ok, {"recovered_access", "refresh", DateTime.add(DateTime.utc_now(), 3600)}}
      end)

      # Should succeed because the existing lock's holder is gone
      assert {:ok, updated} = Tokens.refresh_oauth_token(integration)
      assert updated.access_token == "recovered_access"
    end

    test "double-checks expiry after acquiring lock to avoid redundant refresh" do
      user = insert(:user)

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          access_token: "old",
          token_expires_at: DateTime.add(DateTime.utc_now(), -3600)
        )

      # First process will actually refresh
      expect(GoogleCalendarAPIMock, :refresh_token, 1, fn _int ->
        {:ok, {"new", "refresh", DateTime.add(DateTime.utc_now(), 3600)}}
      end)

      # Run first refresh to completion
      assert {:ok, _updated1} = Tokens.refresh_oauth_token(integration)

      # Second process starts with the SAME (stale) integration map
      # It should acquire lock, then RE-FETCH from DB, see it's NOT expired, and skip API call.
      # (Mock expect is 1, so if it calls again, Mox will fail on exit or during call if configured)
      assert {:ok, updated2} = Tokens.refresh_oauth_token(integration)

      # Second one should have the NEW token from DB re-fetch
      assert updated2.access_token == "new"
    end

    test "skips locking when integration ID is unknown" do
      # Ad-hoc map without ID
      integration = %{
        provider: "google",
        access_token: "old",
        token_expires_at: DateTime.add(DateTime.utc_now(), -3600)
      }

      expect(GoogleCalendarAPIMock, :refresh_token, 2, fn _int ->
        {:ok, {"new", "refresh", DateTime.add(DateTime.utc_now(), 3600)}}
      end)

      # These should BOTH run because they don't lock on :unknown
      assert {:ok, _result} = Tokens.refresh_oauth_token(integration)
      assert {:ok, _result} = Tokens.refresh_oauth_token(integration)
    end

    test "slow refresh does not allow second process to 'steal' the lock prematurely" do
      # This test verifies that even if a refresh takes a long time,
      # a second process still sees the lock as held.
      integration_id = 555_444

      integration = %{
        id: integration_id,
        provider: "google",
        access_token: "old",
        refresh_token: "ref",
        token_expires_at: DateTime.add(DateTime.utc_now(), -3600)
      }

      test_pid = self()

      # First caller blocks for 500ms (much less than 90s, but enough to test concurrency)
      expect(GoogleCalendarAPIMock, :refresh_token, 1, fn _int ->
        send(test_pid, :first_started)
        Process.sleep(500)
        {:ok, {"new", "ref", DateTime.add(DateTime.utc_now(), 3600)}}
      end)

      task1 = Task.async(fn -> Tokens.refresh_oauth_token(integration) end)

      assert_receive :first_started, 1000

      # Second caller should get :refresh_in_progress immediately
      assert {:error, :refresh_in_progress} = Tokens.refresh_oauth_token(integration)

      # Wait for first one to finish
      assert {:ok, _result} = Task.await(task1)
    end
  end

  # The hourly refresh job and a provider API call that finds its token
  # expired must not refresh the same integration at once: each would POST
  # the same refresh token, and with a provider that rotates refresh tokens
  # the later write could persist the older one.
  describe "the refresh job and the API-call refresh" do
    setup do
      user = insert(:user)

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          access_token: "old",
          token_expires_at: DateTime.add(DateTime.utc_now(), -3600)
        )

      {:ok, integration: integration}
    end

    test "exclude each other", %{integration: integration} do
      test_pid = self()

      api_refresh = fn _integration ->
        send(test_pid, {:api_refresh_started, self()})

        receive do
          :proceed -> :ok
        after
          2_000 -> raise "timed out waiting for :proceed"
        end

        {:ok, {"api-access", "api-refresh", DateTime.add(DateTime.utc_now(), 3600)}}
      end

      api_call =
        Task.async(fn ->
          AccessToken.with_access_token(integration, api_refresh, &{:ok, &1})
        end)

      assert_receive {:api_refresh_started, api_pid}, 2_000

      # No GoogleCalendarAPIMock expectation: a second refresh would raise.
      assert {:error, :refresh_in_progress} = Tokens.refresh_oauth_token(integration)

      send(api_pid, :proceed)
      assert {:ok, "api-access"} = Task.await(api_call, 5_000)
    end

    test "an API-call refresh writes its tokens before releasing the lock",
         %{integration: integration} do
      test_pid = self()
      handler_id = {__MODULE__, :persist_under_lock}
      key = Tokens.refresh_lock_key(integration.id)

      :telemetry.attach(
        handler_id,
        [:tymeslot, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if String.starts_with?(metadata.query, ~s(UPDATE "calendar_integrations")) and
               integration.id in metadata.params do
            # Any release this process cast before the write is handled
            # before this call returns, so the table shows the lock as the
            # write saw it.
            _state = :sys.get_state(Lock)

            send(
              test_pid,
              {:written_under_lock, :ets.lookup(:integration_operation_locks, key) != []}
            )
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      refresh = fn _integration ->
        {:ok, {"api-access", "api-refresh", DateTime.add(DateTime.utc_now(), 3600)}}
      end

      assert {:ok, "api-access"} =
               AccessToken.with_access_token(integration, refresh, &{:ok, &1})

      assert_receive {:written_under_lock, true}
    end

    test "an API-call refresh clears a stale sync error", %{integration: integration} do
      integration = set_sync_state(integration, sync_error: "Token refresh failed")

      refresh = fn _integration ->
        {:ok, {"api-access", "api-refresh", DateTime.add(DateTime.utc_now(), 3600)}}
      end

      assert {:ok, "api-access"} =
               AccessToken.with_access_token(integration, refresh, &{:ok, &1})

      assert Repo.get!(CalendarIntegrationSchema, integration.id).sync_error == nil
    end

    test "an API-call refresh keeps the reason an integration needs reconnecting",
         %{integration: integration} do
      integration =
        set_sync_state(integration, sync_error: "Booking calendar deleted", needs_reauth: true)

      refresh = fn _integration ->
        {:ok, {"api-access", "api-refresh", DateTime.add(DateTime.utc_now(), 3600)}}
      end

      assert {:ok, "api-access"} =
               AccessToken.with_access_token(integration, refresh, &{:ok, &1})

      assert Repo.get!(CalendarIntegrationSchema, integration.id).sync_error ==
               "Booking calendar deleted"
    end
  end

  defp set_sync_state(integration, changes) do
    integration
    |> Changeset.change(changes)
    |> Repo.update!()
  end
end
