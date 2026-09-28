defmodule TymeslotWeb.Live.Themes.MeetingManagementThemeTest do
  @moduledoc """
  Which theme the cancel and reschedule pages show. They resolve it as the
  booking pages do (`?theme=`, then the organiser's theme, each only when the
  catalogue knows it, then the default), and the page, its stylesheet and its
  customisation all follow that one answer.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :themes
  @moduletag :live

  import Phoenix.LiveViewTest
  import Tymeslot.Factory

  alias Tymeslot.TestMocks
  alias Tymeslot.ThemeCustomizations

  setup do
    TestMocks.setup_all_mocks()
    :ok
  end

  defp organiser_with_theme(theme_id) do
    user = insert(:user)

    profile =
      insert(:profile,
        user: user,
        username: "host-#{System.unique_integer([:positive])}",
        booking_theme: theme_id
      )

    meeting =
      insert(:meeting,
        organizer_user: user,
        organizer_user_id: user.id,
        organizer_name: user.name,
        status: "confirmed"
      )

    {profile, meeting}
  end

  defp assert_theme(conn, path, key, id) do
    html = conn |> get(path) |> html_response(200)
    assert html =~ ~s(href="/assets/scheduling-theme-#{key}.css")
    assert html =~ "#{key}-theme-wrapper"

    {:ok, view, _html} = live(conn, path)
    assigns = :sys.get_state(view.pid).socket.assigns
    assert assigns.theme_id == id
    # Quill's defaults paint a gradient and Rhythm's a video, so the tokens
    # tell the two themes' customisations apart.
    assert assigns.theme_tokens == ThemeCustomizations.tokens(id, nil)
  end

  for action <- ["cancel", "reschedule"] do
    test "the #{action} page follows ?theme= in its page, stylesheet and customisation",
         %{conn: conn} do
      {profile, meeting} = organiser_with_theme("2")
      path = "/#{profile.username}/meeting/#{meeting.uid}/#{unquote(action)}"

      assert_theme(conn, path, "rhythm", "2")
      assert_theme(conn, path <> "?theme=1", "quill", "1")
    end

    test "the #{action} page falls back to the default theme when the organiser's has left the catalogue",
         %{conn: conn} do
      {profile, meeting} = organiser_with_theme("9")
      path = "/#{profile.username}/meeting/#{meeting.uid}/#{unquote(action)}"

      assert_theme(conn, path, "quill", "1")
    end
  end
end
