defmodule Tymeslot.Integrations.Calendar.AccountCleanupTest do
  use Tymeslot.DataCase, async: false

  @moduletag :integrations
  @moduletag :calendar

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.AccountCleanup
  alias Tymeslot.Security.Encryption

  setup :verify_on_exit!

  defp oauth_calendar(user, attrs) do
    insert(
      :calendar_integration,
      Map.merge(
        %{
          user: user,
          access_token_encrypted: Encryption.encrypt("calendar-access"),
          refresh_token_encrypted: Encryption.encrypt("calendar-refresh"),
          token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        },
        attrs
      )
    )
  end

  test "stops the Google push channel, then revokes the Google grant" do
    user = insert(:user)

    oauth_calendar(user, %{
      provider: "google",
      google_channel_id: "chan-1",
      google_channel_resource_id: "res-1"
    })

    test_pid = self()

    expect(Tymeslot.HTTPClientMock, :request, fn :post, url, body, headers, _opts ->
      send(test_pid, {:stop, url, Jason.decode!(body), headers})
      {:ok, %Req.Response{status: 204, body: ""}}
    end)

    expect(Tymeslot.HTTPClientMock, :post, fn url, body, _headers, _opts ->
      send(test_pid, {:revoke, url, body})
      {:ok, %Req.Response{status: 200, body: ""}}
    end)

    assert AccountCleanup.run(user.id) == :ok

    assert_received {:stop, "https://www.googleapis.com/calendar/v3/channels/stop",
                     %{"id" => "chan-1", "resourceId" => "res-1"}, headers}

    assert {"Authorization", "Bearer calendar-access"} in headers
    assert_received {:revoke, "https://oauth2.googleapis.com/revoke", "token=calendar-refresh"}
  end

  test "revokes the grant even when stopping the channel fails" do
    user = insert(:user)

    oauth_calendar(user, %{
      provider: "google",
      google_channel_id: "chan-1",
      google_channel_resource_id: "res-1"
    })

    expect(Tymeslot.HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
      {:ok, %Req.Response{status: 500, body: ""}}
    end)

    expect(Tymeslot.HTTPClientMock, :post, fn "https://oauth2.googleapis.com/revoke",
                                              _b,
                                              _h,
                                              _o ->
      {:ok, %Req.Response{status: 200, body: ""}}
    end)

    assert AccountCleanup.run(user.id) == :ok
  end

  test "deletes the Microsoft Graph subscription of an Outlook calendar" do
    user = insert(:user)
    oauth_calendar(user, %{provider: "outlook", graph_subscription_id: "sub-1"})

    expect(Tymeslot.HTTPClientMock, :request, fn :delete, url, _body, headers, _opts ->
      assert url == "https://graph.microsoft.com/v1.0/subscriptions/sub-1"
      assert {"Authorization", "Bearer calendar-access"} in headers
      {:ok, %Req.Response{status: 204, body: ""}}
    end)

    assert AccountCleanup.run(user.id) == :ok
  end

  test "makes no call for a CalDAV calendar" do
    user = insert(:user)
    insert(:calendar_integration, user: user, provider: "caldav")

    assert AccountCleanup.run(user.id) == :ok
  end
end
