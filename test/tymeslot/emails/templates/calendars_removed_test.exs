defmodule Tymeslot.Emails.Templates.CalendarsRemovedTest do
  # Not async: the sent email is captured through Swoosh's global
  # `:shared_test_process`.
  use Tymeslot.DataCase, async: false

  @moduletag :emails
  @moduletag :calendar

  alias Tymeslot.Emails.EmailService.IntegrationEmails
  alias Tymeslot.Emails.Templates.CalendarsRemoved

  @integration %{id: 1, name: "Work Nextcloud"}

  describe "render_both/2" do
    test "names the one calendar in the reason and links to the calendar settings" do
      {html, text} = CalendarsRemoved.render_both(@integration, ["Projects"])

      for body <- [html, text] do
        assert body =~ "is no longer on your calendar server, so Tymeslot has stopped using it."
        assert body =~ "Projects"
        assert body =~ "Work Nextcloud"
        assert body =~ "/dashboard/integrations?tab=calendars"
      end

      assert html =~ "<!doctype html>"
      refute text =~ "<mj-"
    end

    test "lists every calendar when several were removed at once" do
      {html, text} = CalendarsRemoved.render_both(@integration, ["Projects", "Team"])

      assert text =~ "These calendars are no longer on your calendar server"
      assert text =~ "- Projects\n- Team"
      assert html =~ "Projects"
      assert html =~ "Team"
    end

    # The names come from the calendar server.
    test "escapes a calendar name in the markup" do
      {html, _text} = CalendarsRemoved.render_both(@integration, ["<b>x</b>", "Team"])

      refute html =~ "<b>x</b>"
      assert html =~ "&lt;b&gt;x&lt;/b&gt;"
    end
  end

  describe "subject/1" do
    test "names one calendar, and counts several" do
      assert CalendarsRemoved.subject(["Projects"]) ==
               "“Projects” is no longer on your calendar server"

      assert CalendarsRemoved.subject(["Projects", "Team"]) ==
               "2 calendars are no longer on your calendar server"
    end
  end

  describe "sending" do
    setup do
      Application.put_env(:swoosh, :shared_test_process, self())
      on_exit(fn -> Application.delete_env(:swoosh, :shared_test_process) end)
    end

    test "goes to the owner" do
      user = insert(:user, email: "owner@example.com", name: "Olivia")

      assert {:ok, _result} =
               IntegrationEmails.send_calendars_removed_notification(user, @integration, [
                 "Projects"
               ])

      assert_received {:email, email}
      assert email.to == [{"Olivia", "owner@example.com"}]
      assert email.subject == "“Projects” is no longer on your calendar server"
    end

    test "is written in the owner's language" do
      user = insert(:user, locale: "de")

      assert {:ok, _result} =
               IntegrationEmails.send_calendars_removed_notification(user, @integration, [
                 "Projects"
               ])

      assert_received {:email, email}

      assert email.subject ==
               "Der Kalender „Projects“ ist auf Ihrem Kalenderserver nicht mehr vorhanden"

      assert email.text_body =~ "Kalendereinstellungen"
    end
  end
end
