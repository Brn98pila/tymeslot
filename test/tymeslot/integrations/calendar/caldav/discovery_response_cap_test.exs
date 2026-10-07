defmodule Tymeslot.Integrations.Calendar.CalDAV.DiscoveryResponseCapTest do
  # Runs the real HTTPClient, so the byte budget is enforced where it is in
  # production: mid-transfer, below every caller.
  use Tymeslot.DataCase, async: false

  @moduletag :calendar
  @moduletag :integrations

  import Tymeslot.ConfigTestHelpers

  alias Plug.Conn
  alias Req.Test, as: ReqTest
  alias Tymeslot.Integrations.Calendar.Discovery
  alias Tymeslot.Integrations.Calendar.Shared.DiscoveryCache

  @propfind_budget 4 * 1024 * 1024

  setup do
    with_config(:tymeslot, :http_client_module, Tymeslot.Infrastructure.HTTPClient)
    DiscoveryCache.clear_all()
    :ok
  end

  test "connecting a CalDAV server whose calendar listing outgrows the budget says so" do
    stub_propfind_body(String.duplicate(" ", @propfind_budget + 1))

    assert {:error, %{discovery: message}} = Discovery.maybe_discover_calendars(attrs())
    assert message =~ "more data than Tymeslot can process at once"
  end

  test "a calendar listing exactly at the budget is read" do
    listing = """
    <D:multistatus xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
      <D:response>
        <D:href>/calendars/user/work/</D:href>
        <D:propstat>
          <D:prop>
            <D:displayname>Work</D:displayname>
            <D:resourcetype><D:collection/><C:calendar/></D:resourcetype>
          </D:prop>
          <D:status>HTTP/1.1 200 OK</D:status>
        </D:propstat>
      </D:response>
    </D:multistatus>
    """

    # Trailing whitespace after the root element is well-formed, so the
    # listing can be padded to the budget's last byte.
    stub_propfind_body(listing <> String.duplicate(" ", @propfind_budget - byte_size(listing)))

    assert {:ok, %{calendar_paths: ["/calendars/user/work/"]}} =
             Discovery.maybe_discover_calendars(attrs())
  end

  defp attrs do
    %{
      provider: "caldav",
      base_url: "https://caldav.example.com",
      username: "user",
      password: "pass",
      user_id: 1
    }
  end

  defp stub_propfind_body(body) do
    ReqTest.stub(:tymeslot_http, fn conn ->
      conn
      |> Conn.put_resp_content_type("application/xml")
      |> Conn.resp(207, body)
    end)
  end
end
