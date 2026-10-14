defmodule TymeslotWeb.Dashboard.CalendarGrid.RepeatSeriesStagingLiveViewTest do
  @moduledoc """
  The repeat editor in an event's details, end to end: a pattern is staged
  over several controls and written once when it is saved, built from the
  start the event has when it is saved, with the ends a change of it and
  the following occurrences can take, and what Outlook refuses said before
  anything is written.

  The series is `RepeatSeriesFixtures`' weekly one from 30 September 2026,
  opened on its 14 October occurrence; only the HTTP client is mocked.
  """

  use TymeslotWeb.LiveCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :live
  @moduletag :integration

  import Mox
  import Phoenix.LiveViewTest
  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory
  import TymeslotWeb.RepeatSeriesFixtures

  alias Plug.Test
  alias Tymeslot.Integrations.Calendar.Google.CalendarAPI, as: GoogleAPI
  alias Tymeslot.Integrations.Calendar.ICalBuilder.LineFolder
  alias Tymeslot.Integrations.Calendar.Operations
  alias Tymeslot.Integrations.Calendar.Outlook.CalendarAPI, as: OutlookAPI

  setup :set_mox_global
  setup :verify_on_exit!

  @task_timeout 5_000
  @form "#recurrence-editor-form-update_event_recurrence"
  @series_url "https://caldav.example.com/cal/weekly-standup.ics"
  @all_summary "Repeats monthly on day 30"
  @following_summary "Repeats monthly on day 14"

  defp swap_env(key, module) do
    previous = Application.get_env(:tymeslot, key)
    Application.put_env(:tymeslot, key, module)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:tymeslot, key, previous),
        else: Application.delete_env(:tymeslot, key)
    end)
  end

  setup %{conn: conn} do
    swap_env(:calendar_module, Operations)
    swap_env(:google_calendar_api_module, GoogleAPI)
    swap_env(:outlook_calendar_api_module, OutlookAPI)

    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    _profile = insert(:profile, user: user, timezone: "Etc/UTC")
    conn = conn |> Test.init_test_session(%{}) |> fetch_session() |> log_in_user(user)

    {:ok, conn: conn, user: user}
  end

  describe "a one-off Outlook event on the 31st" do
    setup %{user: user} do
      integration =
        oauth_integration(user, "outlook", "https://graph.microsoft.com/Calendars.ReadWrite")

      event =
        occurrence(integration, %{
          provider: "outlook",
          uid: "one-off-31",
          provider_event_id: "one-off-31",
          start_at: ~U[2026-12-31 09:00:00Z],
          end_at: ~U[2026-12-31 10:00:00Z],
          recurrence_rule: nil
        })

      serve(%{"id" => "one-off-31"})
      %{event: event}
    end

    test "says why Outlook refuses a monthly pattern, and saving writes nothing", %{
      conn: conn,
      event: event
    } do
      lv = open(conn, event, "2026-12-31")
      html = pick(lv, %{"freq" => "monthly"})

      assert html =~ "Repeats monthly on day 31"
      assert has_element?(lv, "#{@form} ~ [role='alert']", "Outlook can't skip the months")

      save(lv)
      assert render(lv) =~ "Outlook can&#39;t skip the months"
      refute has_element?(lv, "#recurrence-prompt-modal")
      refute_receive {:request, _method, _url, _body}, 200
    end
  end

  describe "an end when the following ones start from the occurrence" do
    # 30 September, 7 and 14 October: two occurrences come before the split,
    # so of ten in all, eight are left to start again from it.
    test "a count is what is left of the series", %{conn: conn, user: user} do
      event =
        user
        |> caldav_integration()
        |> caldav_occurrence(%{
          recurrence_rule: "FREQ=WEEKLY;BYDAY=WE;COUNT=10",
          raw_ical: caldav_series("FREQ=WEEKLY;BYDAY=WE;COUNT=10")
        })

      lv = open(conn, event)
      pick(lv, %{"interval" => "2"})

      expect_puts(2)
      save(lv)

      assert prompt_summary(lv, :all) =~ "Repeats every 2 weeks on Wed for 10 occurrences"
      assert prompt_summary(lv, :following) =~ "Repeats every 2 weeks on Wed for 8 occurrences"
      confirm_scope(lv, "following")

      [{_tail_url, tail}, {@series_url, _head}] = await_puts(2)
      assert "RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=WE;COUNT=8" in LineFolder.unfold_lines(tail)
    end

    test "an end before the occurrence says why this and following is not offered", %{
      conn: conn,
      user: user
    } do
      event = user |> caldav_integration() |> caldav_occurrence()

      lv = open(conn, event)
      pick(lv, %{"end_type" => "until"})
      pick(lv, %{"until" => "2026-10-10"})
      save(lv)

      assert prompt_summary(lv, :all) =~ "until 10 October 2026"

      assert has_element?(
               lv,
               "#recurrence-scope-following [data-role='scope-refusal']",
               "the new end comes before this event"
             )

      refute has_element?(lv, "#recurrence-prompt-modal [phx-value-scope='following']")
      assert has_element?(lv, "#recurrence-prompt-modal [phx-value-scope='all']")
    end
  end

  # A one-off given a pattern, then moved to another day before the pattern
  # is saved: the pattern is built from the day it is saved on.
  describe "a staged pattern on a one-off that moves" do
    test "is built from the event's new start when saved", %{conn: conn, user: user} do
      integration = oauth_integration(user, "google", "https://www.googleapis.com/auth/calendar")

      event =
        occurrence(integration, %{
          provider: "google",
          uid: "one-off",
          provider_event_id: "one-off",
          start_at: ~U[2026-10-12 09:00:00Z],
          end_at: ~U[2026-10-12 10:00:00Z],
          recurrence_rule: nil
        })

      serve(%{"id" => "one-off", "status" => "confirmed"})
      lv = open(conn, event, "2026-10-12")

      pick(lv, %{"freq" => "monthly"})
      html = pick(lv, %{"on" => "2:mo"})
      assert html =~ "Repeats monthly on the second Monday"

      html =
        lv
        |> element("#calendar-grid")
        |> render_hook("update_event_time", %{
          "start-date" => "2026-10-13",
          "start-time" => "09:00",
          "end-date" => "2026-10-13",
          "end-time" => "10:00"
        })

      assert html =~ "Repeats monthly on the second Tuesday"
      assert_receive {:request, _method, _url, _time_write}, @task_timeout

      save(lv)

      assert_receive {:request, _method, _url, body}, @task_timeout
      assert Jason.decode!(body)["recurrence"] == ["RRULE:FREQ=MONTHLY;BYDAY=2TU"]
    end
  end

  describe "staging" do
    setup %{user: user} do
      integration =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          base_url: "https://caldav.example.com",
          calendar_paths: ["/cal/"]
        )

      event =
        occurrence(integration, %{
          provider: "caldav",
          provider_calendar_id: "/cal/",
          uid: "weekly-standup_20261014T090000",
          provider_event_id: "/cal/weekly-standup.ics",
          provider_metadata: %{"uid" => "weekly-standup"},
          etag: "\"etag-1\"",
          raw_ical: caldav_series()
        })

      %{event: event}
    end

    # Several controls make one pattern, and nothing is written until it is
    # saved, once.
    test "builds a pattern over several controls and writes it once", %{
      conn: conn,
      event: event
    } do
      lv = open(conn, event)

      pick(lv, %{"freq" => "monthly"})
      pick(lv, %{"end_type" => "count"})
      html = pick(lv, %{"count" => "6"})

      assert html =~ "Repeats monthly on day 30 for 6 occurrences"
      refute has_element?(lv, "#recurrence-prompt-modal")
      refute_receive {:put, _url, _body}, 100

      expect_puts(1)
      save(lv)
      confirm_scope(lv, "all")

      assert [{@series_url, body}] = await_puts(1)
      assert "RRULE:FREQ=MONTHLY;COUNT=6" in LineFolder.unfold_lines(body)
    end

    test "discarding drops the staged pattern and writes nothing", %{conn: conn, event: event} do
      lv = open(conn, event)
      pick(lv, %{"freq" => "monthly"})

      assert has_element?(lv, "button[phx-click='save_event_recurrence']", "Save repeat")

      html =
        lv
        |> element("button[phx-click='discard_event_recurrence']", "Discard changes")
        |> render_click()

      assert html =~ "Repeats weekly on Wed"
      refute has_element?(lv, "button[phx-click='save_event_recurrence']")
      refute_receive {:put, _url, _body}, 100
    end

    test "cancelling the scope prompt keeps the staged pattern", %{conn: conn, event: event} do
      lv = stage_monthly_and_save(conn, event)

      lv
      |> element("#recurrence-prompt-modal button", "Cancel")
      |> render_click()

      assert render(lv) =~ @all_summary
      assert has_element?(lv, "button[phx-click='save_event_recurrence']")
    end
  end

  # Opens the occurrence, switches it to monthly, which the editor shows
  # from the series' start, and saves it into the scope prompt.
  defp stage_monthly_and_save(conn, event) do
    lv = open(conn, event)
    html = pick(lv, %{"freq" => "monthly"})
    assert html =~ @all_summary

    save(lv)

    assert has_element?(lv, "#recurrence-scope-all [data-role='scope-summary']", @all_summary)

    assert has_element?(
             lv,
             "#recurrence-scope-following [data-role='scope-summary']",
             @following_summary
           )

    lv
  end
end
