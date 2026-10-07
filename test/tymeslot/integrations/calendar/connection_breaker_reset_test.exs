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

  alias Tymeslot.ExchangeFixtures
  alias Tymeslot.Infrastructure.CalendarCircuitBreaker
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.Connection
  alias Tymeslot.Integrations.Calendar.Reconnection
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Test.CalDAVAccountStub

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    host = "dav-#{System.unique_integer([:positive])}.example.com"

    # A URL that names no known server, so the client keeps the `:caldav`
    # breaker rather than one for a detected server type.
    inserted =
      insert(:calendar_integration,
        provider: "caldav",
        base_url: "https://#{host}/cal/",
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

  # Discovery is what a reconnect and a connection check run, and it goes
  # through the host breaker: an open one would refuse the very request that
  # can show the server is back, so these are let past it.
  test "a reconnect reaches a server its breaker refuses, and closes the breaker", %{
    integration: integration,
    host: host
  } do
    stub_discovery(["/cal/bob/a/"])

    params = %{"url" => "https://#{host}/cal/", "username" => "bob", "password" => "pass"}

    assert {:ok, :needs_calendar_selection, payload} = Reconnection.reconnect(integration, params)
    assert [%{path: path}] = payload.calendars

    assert {:ok, _updated} = Reconnection.finalise_account_change(integration, payload, [path])
    assert %{status: :closed} = CalendarCircuitBreaker.status(:caldav, host)
  end

  test "checking a connection reaches a server its breaker refuses, and closes the breaker", %{
    integration: integration,
    host: host
  } do
    stub_discovery(["/cal/bob/a/"])

    assert {:ok, _integration} =
             Connection.validate_connection(integration, integration.user_id)

    assert %{status: :closed} = CalendarCircuitBreaker.status(:caldav, host)
  end

  test "an Exchange connection test reaches a server its breaker refuses, and closes it" do
    host = "ews-#{System.unique_integer([:positive])}.example.com"

    inserted =
      insert(:calendar_integration,
        provider: "exchange",
        base_url: "https://#{host}/EWS/Exchange.asmx",
        username_encrypted: Encryption.encrypt("user@example.com"),
        password_encrypted: Encryption.encrypt("secret"),
        provider_account_email: "user@example.com",
        calendar_list: []
      )

    {:ok, integration} = CalendarIntegrationQueries.get(inserted.id)
    trip_host_breaker(:exchange, host)

    stub(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
      {:ok, %Req.Response{status: 200, body: ExchangeFixtures.find_folder_response()}}
    end)

    assert {:ok, _message} = Connection.test_connection(integration)
    assert %{status: :closed} = CalendarCircuitBreaker.status(:exchange, host)
  end

  # One iCloud account reaching iCloud says nothing about the failures every
  # other account on that host saw.
  test "a connection test leaves a server shared by many accounts alone" do
    inserted =
      insert(:calendar_integration,
        provider: "apple",
        base_url: "https://caldav.icloud.com",
        calendar_paths: ["/123/calendars/home/"]
      )

    {:ok, integration} = CalendarIntegrationQueries.get(inserted.id)
    trip_host_breaker(:apple, "caldav.icloud.com")

    stub(Tymeslot.HTTPClientMock, :request, fn :propfind, _url, _body, _headers, _opts ->
      {:ok, %Req.Response{status: 207, body: ""}}
    end)

    assert {:ok, _message} = Connection.test_connection(integration, scope: :background)
    assert %{status: :open} = CalendarCircuitBreaker.status(:apple, "caldav.icloud.com")
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

  defp stub_discovery(calendars) do
    stub(Tymeslot.HTTPClientMock, :request, fn method, url, body, _headers, _opts ->
      CalDAVAccountStub.answer(%{calendars: calendars}, method, url, body)
    end)
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
