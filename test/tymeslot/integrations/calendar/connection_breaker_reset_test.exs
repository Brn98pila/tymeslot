defmodule Tymeslot.Integrations.Calendar.ConnectionBreakerResetTest do
  @moduledoc """
  A self-hosted calendar server's calls run through a breaker keyed by its
  host. Once it has opened, an integration whose syncs are paused sends that
  server no traffic, so nothing would close it again until it timed out; a
  connection test that reaches the server is the evidence that it is back.
  """

  # Host breakers are global processes shared with every other test, and
  # DataCase resets them in its setup.
  use Tymeslot.DataCase, async: false

  @moduletag :integrations
  @moduletag :calendar
  @moduletag :capture_log

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Infrastructure.CalendarCircuitBreaker
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.Connection
  alias Tymeslot.Integrations.Calendar.Reconnection

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    host = "dav-#{System.unique_integer([:positive])}.example.com"

    inserted =
      insert(:calendar_integration,
        provider: "caldav",
        base_url: "https://#{host}/remote.php/dav",
        calendar_paths: []
      )

    # As every caller has it: read back, credentials decrypted.
    {:ok, integration} = CalendarIntegrationQueries.get(inserted.id)

    trip_host_breaker(:caldav, host)
    %{integration: integration, host: host}
  end

  test "a connection test that reaches the server closes its host breaker", %{
    integration: integration,
    host: host
  } do
    stub(Tymeslot.HTTPClientMock, :request, fn :propfind, _url, _body, _headers, _opts ->
      {:ok, %Req.Response{status: 207, body: ""}}
    end)

    assert {:ok, _message} = Connection.test_connection(integration, scope: :background)
    assert %{status: :closed} = CalendarCircuitBreaker.status(:caldav, host)
  end

  # A reconnect only persists after discovery has reached the server with
  # the new credentials.
  test "a completed reconnect closes its server's host breaker", %{
    integration: integration,
    host: host
  } do
    payload = %{
      credentials: %{url: "https://#{host}/remote.php/dav", username: "bob", password: "pass"},
      calendars: [%{"id" => "/a/", "path" => "/a/", "name" => "A", "type" => "calendar"}]
    }

    assert {:ok, _updated} = Reconnection.finalise_account_change(integration, payload, ["/a/"])
    assert %{status: :closed} = CalendarCircuitBreaker.status(:caldav, host)
  end

  test "a connection test that fails leaves the breaker open", %{
    integration: integration,
    host: host
  } do
    stub(Tymeslot.HTTPClientMock, :request, fn :propfind, _url, _body, _headers, _opts ->
      {:ok, %Req.Response{status: 401, body: ""}}
    end)

    assert {:error, _reason} = Connection.test_connection(integration, scope: :background)
    assert %{status: :open} = CalendarCircuitBreaker.status(:caldav, host)
  end

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
