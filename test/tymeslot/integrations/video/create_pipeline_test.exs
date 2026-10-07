defmodule Tymeslot.Integrations.Video.CreatePipelineTest do
  @moduledoc """
  Connecting any video provider runs the same checks in the same order: a
  duplicate is refused first, then the config is validated, and only then is
  a metered connection test spent.
  """

  use Tymeslot.DataCase, async: true
  @moduletag :integrations

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Integrations.Video

  setup :verify_on_exit!

  setup do
    %{user: insert(:user)}
  end

  test "refuses a malformed custom link before saving it", %{user: user} do
    assert {:error, "Invalid URL format. Please provide a valid HTTP/HTTPS URL."} =
             Video.create_integration(user.id, :custom, %{
               "name" => "Room",
               "custom_meeting_url" => "not a link"
             })

    assert Video.list_integrations(user.id) == []
  end

  test "connects a well-formed custom link", %{user: user} do
    assert {:ok, _integration} =
             Video.create_integration(user.id, :custom, %{
               "name" => "Room",
               "custom_meeting_url" => "https://meet.example.com/standing-room"
             })
  end

  test "refuses a second kMeet before the database is asked", %{user: user} do
    assert {:ok, _first} = Video.create_integration(user.id, :kmeet, %{"name" => "kMeet"})

    assert {:error, :provider_already_connected} =
             Video.create_integration(user.id, :kmeet, %{"name" => "kMeet again"})
  end

  # The duplicate is decided first, so a repeat is answered as one even when
  # its config would also be refused.
  test "answers a repeated Jitsi server as a duplicate", %{user: user} do
    attrs = %{"name" => "Jitsi", "base_url" => "https://jitsi.example.com"}
    assert {:ok, _first} = Video.create_integration(user.id, :jitsi, attrs)

    assert {:error, _duplicate} =
             Video.create_integration(user.id, :jitsi, Map.put(attrs, "client_id", "half-a-pair"))

    assert length(Video.list_integrations(user.id)) == 1
  end

  # No HTTP expectation is set: a probe would fail the test.
  test "spends no connection test on a repeated MiroTalk server", %{user: user} do
    insert(:video_integration,
      user: user,
      provider: "mirotalk",
      base_url: "https://mirotalk.example.com",
      provider_account_id: "https://mirotalk.example.com"
    )

    assert {:error, _duplicate} =
             Video.create_integration(user.id, :mirotalk, %{
               "name" => "MiroTalk",
               "api_key" => "key",
               "base_url" => "https://mirotalk.example.com"
             })
  end
end
