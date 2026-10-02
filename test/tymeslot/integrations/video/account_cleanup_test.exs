defmodule Tymeslot.Integrations.Video.AccountCleanupTest do
  use Tymeslot.DataCase, async: false

  @moduletag :integrations
  @moduletag :video

  import Mox
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Integrations.Video.AccountCleanup
  alias Tymeslot.Security.Encryption

  setup :verify_on_exit!

  defp oauth_video(user, provider, access, refresh) do
    insert(:video_integration,
      user: user,
      provider: provider,
      access_token_encrypted: Encryption.encrypt(access),
      refresh_token_encrypted: Encryption.encrypt(refresh),
      token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
    )
  end

  test "revokes a Google Meet grant with its refresh token" do
    user = insert(:user)
    oauth_video(user, "google_meet", "meet-access", "meet-refresh")

    expect(Tymeslot.HTTPClientMock, :post, fn url, body, _headers, _opts ->
      assert url == "https://oauth2.googleapis.com/revoke"
      assert body == "token=meet-refresh"
      {:ok, %Req.Response{status: 200, body: ""}}
    end)

    assert AccountCleanup.run(user.id) == :ok
  end

  test "revokes a Zoom grant with its access token and the app's credentials" do
    with_config(:tymeslot, :zoom_oauth,
      client_id: "zoom-id",
      client_secret: "zoom-secret",
      state_secret: "zoom-state"
    )

    stub(Tymeslot.ZoomOAuthHelperMock, :validate_token, fn _config -> {:ok, :valid} end)

    user = insert(:user)
    oauth_video(user, "zoom", "zoom-access", "zoom-refresh")

    expect(Tymeslot.HTTPClientMock, :post, fn url, _body, headers, _opts ->
      assert url == "https://zoom.us/oauth/revoke?token=zoom-access"
      assert {"Authorization", "Basic " <> Base.encode64("zoom-id:zoom-secret")} in headers
      {:ok, %Req.Response{status: 200, body: ~s({"status":"success"})}}
    end)

    assert AccountCleanup.run(user.id) == :ok
  end

  test "makes no call for Teams or MiroTalk" do
    user = insert(:user)
    oauth_video(user, "teams", "teams-access", "teams-refresh")
    insert(:video_integration, user: user, provider: "mirotalk")

    assert AccountCleanup.run(user.id) == :ok
  end
end
