defmodule Tymeslot.Integrations.HealthCheck.SchedulerCircuitBreakerTest do
  # Host breakers are dynamically registered, global processes shared with
  # every other test, and DataCase resets them in its setup; async: false
  # keeps a concurrently running module from resetting the one tripped here.
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  import Tymeslot.Factory

  alias Tymeslot.Infrastructure.CalendarCircuitBreaker
  alias Tymeslot.Integrations.HealthCheck.Scheduler
  alias Tymeslot.Workers.IntegrationHealthWorker

  @moduletag :integrations
  @moduletag :capture_log

  describe "schedule_all/1 with a self-hosted calendar whose server is down" do
    test "skips the integrations on that server and checks the rest" do
      user = insert(:user)

      down =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          is_active: true,
          base_url: "https://dav.down.example/remote.php/dav"
        )

      up =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          is_active: true,
          base_url: "https://dav.up.example/remote.php/dav"
        )

      trip_host_breaker(:caldav, "dav.down.example")

      assert :ok = Scheduler.schedule_all(force: true)

      refute_enqueued(
        worker: IntegrationHealthWorker,
        args: %{"type" => "calendar", "integration_id" => down.id}
      )

      assert_enqueued(
        worker: IntegrationHealthWorker,
        args: %{"type" => "calendar", "integration_id" => up.id}
      )
    end
  end

  describe "CalendarCircuitBreaker host breakers" do
    test "reset/2 closes the breaker a server's calls tripped" do
      host = "reset-#{System.unique_integer([:positive])}.example.com"
      trip_host_breaker(:caldav, host)

      assert :ok = CalendarCircuitBreaker.reset(:caldav, host)
      assert %{status: :closed} = CalendarCircuitBreaker.status(:caldav, host)
    end
  end

  # Fails calls through the same host breaker CalDAV traffic uses until it
  # opens. `status/2` is a call to the breaker process, queued behind the
  # outcome casts, so its answer reflects every failure recorded here.
  defp trip_host_breaker(provider, host) do
    threshold = CalendarCircuitBreaker.get_config(provider).failure_threshold

    for _attempt <- 1..threshold do
      CalendarCircuitBreaker.with_breaker(provider, [host: host], fn ->
        {:provider_error, :unreachable}
      end)
    end

    assert %{status: :open} = CalendarCircuitBreaker.status(provider, host)
  end
end
