defmodule Tymeslot.Auth.AccountDeletion.ExternalCleanupTest do
  use Tymeslot.DataCase, async: false

  @moduletag :auth
  @moduletag :integrations

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Auth.AccountDeletion.ExternalCleanup
  alias Tymeslot.Security.Encryption

  setup :verify_on_exit!

  test "one step failing outright does not stop the others" do
    user = insert(:user)

    insert(:calendar_integration,
      user: user,
      provider: "google",
      refresh_token_encrypted: Encryption.encrypt("calendar-refresh"),
      access_token_encrypted: Encryption.encrypt("calendar-access"),
      token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
    )

    insert(:slack_integration, user: user)
    test_pid = self()

    expect(Tymeslot.HTTPClientMock, :post, 2, fn url, _body, _headers, _opts ->
      send(test_pid, {:post, url})

      if String.contains?(url, "slack.com"),
        do: raise("Slack is down"),
        else: {:ok, %Req.Response{status: 200, body: ""}}
    end)

    assert ExternalCleanup.run(user) == :ok
    assert_received {:post, "https://oauth2.googleapis.com/revoke"}
    assert_received {:post, "https://slack.com/api/auth.revoke"}
  end
end
