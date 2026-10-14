defmodule TymeslotWeb.Dashboard.CalendarGrid.RepeatSeriesAnchorLiveViewTest do
  @moduledoc """
  A weekly series that began on Wednesday 30 September, opened on its
  14 October occurrence and switched to monthly "on the start's day", end to
  end on Google, Outlook and CalDAV.

  The editor builds the pattern from the series' first start, which is what
  a rule written to all of it is read from: "on day 30". Saving asks for a
  scope, and the prompt shows what each one writes: all events "on day 30",
  this and following, a new series from 14 October, "on day 14". The tests
  check the provider receives exactly that, and that Outlook, which cannot
  skip the months without a 30th, has its "All events" refused in the
  prompt rather than written.

  The grid is moved to 14 October so the dates are the same on any day the
  suite runs. As in `RepeatPatternsLiveViewTest`, only the HTTP client is
  mocked.
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

  alias Plug.Test
  alias Tymeslot.Clock
  alias Tymeslot.Integrations.Calendar.Google.CalendarAPI, as: GoogleAPI
  alias Tymeslot.Integrations.Calendar.ICalBuilder.LineFolder
  alias Tymeslot.Integrations.Calendar.Operations
  alias Tymeslot.Integrations.Calendar.Outlook.CalendarAPI, as: OutlookAPI
  alias Tymeslot.Integrations.Calendar.SeriesRuleQueries
  alias Tymeslot.Security.Encryption

  setup :set_mox_global
  setup :verify_on_exit!

  @task_timeout 5_000
  @form "#recurrence-editor-form-update_event_recurrence"

  @series_start ~U[2026-09-30 09:00:00Z]
  @opened ~U[2026-10-14 09:00:00Z]
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

  describe "a Google series" do
    setup %{user: user} do
      integration = oauth_integration(user, "google", "https://www.googleapis.com/auth/calendar")
      cache_series_rule(integration, "series1")

      event =
        occurrence(integration, %{
          provider: "google",
          uid: "weekly_20261014T090000Z",
          provider_event_id: "series1_20261014T090000Z",
          recurring_event_id: "series1"
        })

      serve(%{
        "id" => "series1",
        "iCalUID" => "series1@google.com",
        "summary" => "Weekly sync",
        "start" => %{"dateTime" => "2026-09-30T09:00:00Z", "timeZone" => "Etc/UTC"},
        "end" => %{"dateTime" => "2026-09-30T10:00:00Z", "timeZone" => "Etc/UTC"},
        "recurrence" => ["RRULE:FREQ=WEEKLY;BYDAY=WE"]
      })

      %{event: event}
    end

    test "all events repeats on the series' day, as the prompt says", %{conn: conn, event: event} do
      lv = stage_monthly_and_save(conn, event)
      confirm_scope(lv, "all")

      assert [{:get, _master, _read}, {:patch, _url, body}] = await_requests(2)
      # The master still starts on 30 September, so the 30th.
      assert Jason.decode!(body)["recurrence"] == ["RRULE:FREQ=MONTHLY"]
    end

    test "this and following starts a series on the 14th, as the prompt says", %{
      conn: conn,
      event: event
    } do
      lv = stage_monthly_and_save(conn, event)
      confirm_scope(lv, "following")

      assert [_master, _list, {:post, _url, tail}, {:patch, _head_url, _head}] =
               await_requests(4)

      tail = Jason.decode!(tail)
      assert tail["recurrence"] == ["RRULE:FREQ=MONTHLY"]
      assert tail["start"]["dateTime"] =~ "2026-10-14T09:00:00"
    end
  end

  describe "an Outlook series" do
    setup %{user: user} do
      integration =
        oauth_integration(user, "outlook", "https://graph.microsoft.com/Calendars.ReadWrite")

      cache_series_rule(integration, "master-1")

      event =
        occurrence(integration, %{
          provider: "outlook",
          uid: "weekly-occurrence-20261014",
          provider_event_id: "occurrence-1",
          recurring_event_id: "master-1",
          provider_metadata: %{"type" => "occurrence"}
        })

      serve(%{
        "id" => "master-1",
        "type" => "seriesMaster",
        "subject" => "Weekly sync",
        "isAllDay" => false,
        "start" => %{"dateTime" => "2026-09-30T09:00:00.0000000", "timeZone" => "UTC"},
        "end" => %{"dateTime" => "2026-09-30T10:00:00.0000000", "timeZone" => "UTC"},
        "originalStartTimeZone" => "UTC",
        "recurrence" => %{
          "pattern" => %{"type" => "weekly", "interval" => 1, "daysOfWeek" => ["wednesday"]},
          "range" => %{"type" => "noEnd", "startDate" => "2026-09-30"}
        }
      })

      %{event: event}
    end

    # Graph would move the 30th to 28 February rather than skip February.
    test "all events is refused in the prompt, with the reason, and not offered", %{
      conn: conn,
      event: event
    } do
      lv = stage_monthly_and_save(conn, event)

      assert has_element?(
               lv,
               "#recurrence-scope-all [data-role='scope-refusal']",
               "Outlook can't skip the months"
             )

      refute has_element?(lv, "#recurrence-prompt-modal [phx-value-scope='all']")
      refute_receive {:request, _method, _url, _body}, 200
    end

    test "this and following starts a series on the 14th, as the prompt says", %{
      conn: conn,
      event: event
    } do
      lv = stage_monthly_and_save(conn, event)
      confirm_scope(lv, "following")

      requests = await_requests(5)
      assert {:post, _url, tail} = Enum.find(requests, &match?({:post, _url, _body}, &1))

      assert %{
               "pattern" => %{"type" => "absoluteMonthly", "dayOfMonth" => 14},
               "range" => %{"startDate" => "2026-10-14"}
             } = Jason.decode!(tail)["recurrence"]
    end

    test "all events of a yearly pattern is written on the series' date", %{
      conn: conn,
      event: event
    } do
      lv = open(conn, event)
      pick(lv, %{"freq" => "yearly"})

      assert render(lv) =~ "Repeats yearly on 30 September"

      save(lv)
      assert has_element?(lv, "#recurrence-scope-following", "Repeats yearly on 14 October")
      confirm_scope(lv, "all")

      assert [{:get, _master, _read}, {:patch, _url, body}] = await_requests(2)

      assert %{"type" => "absoluteYearly", "dayOfMonth" => 30, "month" => 9} =
               Jason.decode!(body)["recurrence"]["pattern"]
    end
  end

  describe "a CalDAV series" do
    @series_url "https://caldav.example.com/cal/weekly-standup.ics"

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

    test "all events rewrites the master's rule, read from its 30 September start", %{
      conn: conn,
      event: event
    } do
      expect_puts(1)
      lv = stage_monthly_and_save(conn, event)
      confirm_scope(lv, "all")

      assert [{@series_url, body}] = await_puts(1)
      lines = LineFolder.unfold_lines(body)
      assert "DTSTART:20260930T090000Z" in lines
      assert "RRULE:FREQ=MONTHLY" in lines
    end

    test "this and following starts a series on the 14th, as the prompt says", %{
      conn: conn,
      event: event
    } do
      expect_puts(2)
      lv = stage_monthly_and_save(conn, event)
      confirm_scope(lv, "following")

      [{tail_url, tail}, {@series_url, _head}] = await_puts(2)
      assert tail_url != @series_url

      lines = LineFolder.unfold_lines(tail)
      assert Enum.any?(lines, &(&1 =~ ~r/^DTSTART.*20261014T0900/))
      assert "RRULE:FREQ=MONTHLY" in lines
    end
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

  defp oauth_integration(user, provider, scope) do
    insert(:calendar_integration,
      user: user,
      provider: provider,
      access_token_encrypted: Encryption.encrypt("valid_token"),
      refresh_token_encrypted: Encryption.encrypt("refresh_token"),
      token_expires_at: DateTime.add(Clock.utc_now(), 3600),
      oauth_scope: scope
    )
  end

  # The series' rule and first start, as the sync reads them from the master.
  defp cache_series_rule(integration, master_id) do
    {:ok, _row} =
      SeriesRuleQueries.put(integration.id, master_id, %{
        rule: "FREQ=WEEKLY;BYDAY=WE",
        master_start: @series_start,
        fetched_at: DateTime.utc_now()
      })
  end

  defp occurrence(integration, attrs) do
    insert(
      :provider_calendar_event,
      Map.merge(
        %{
          calendar_integration: integration,
          provider_calendar_id: "team-calendar",
          summary: "Weekly sync",
          start_at: @opened,
          end_at: DateTime.add(@opened, 1, :hour),
          all_day: false,
          timezone: "Etc/UTC",
          recurrence_rule: "FREQ=WEEKLY;BYDAY=WE",
          sync_state: "synced"
        },
        attrs
      )
    )
  end

  defp caldav_series do
    Enum.join(
      [
        "BEGIN:VCALENDAR",
        "VERSION:2.0",
        "BEGIN:VEVENT",
        "UID:weekly-standup",
        "DTSTAMP:20260901T090000Z",
        "DTSTART:20260930T090000Z",
        "DTEND:20260930T100000Z",
        "RRULE:FREQ=WEEKLY;BYDAY=WE",
        "SUMMARY:Weekly standup",
        "END:VEVENT",
        "END:VCALENDAR"
      ],
      "\r\n"
    ) <> "\r\n"
  end

  defp open(conn, event, date \\ "2026-10-14") do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    lv
    |> element("#calendar-grid")
    |> render_hook("navigate_to_day", %{"date" => date})

    lv
    |> element("#calendar-grid")
    |> render_hook("show_event", %{"event-id" => to_string(event.id)})

    assert has_element?(lv, @form)
    lv
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

  defp pick(lv, fields), do: lv |> form(@form, fields) |> render_change()

  defp save(lv) do
    lv
    |> element("button[phx-click='save_event_recurrence']", "Save repeat")
    |> render_click()
  end

  defp confirm_scope(lv, scope) do
    lv
    |> element("#recurrence-prompt-modal [phx-value-scope='#{scope}']")
    |> render_click()
  end

  defp serve(master) do
    test_pid = self()

    stub(Tymeslot.HTTPClientMock, :request, fn method, url, body, _headers, _opts ->
      send(test_pid, {:request, method, url, body})

      case method do
        :post ->
          {:ok, %Req.Response{status: 200, body: Jason.encode!(%{"id" => "tail1"})}}

        :delete ->
          {:ok, %Req.Response{status: 204, body: ""}}

        _read_or_write ->
          {:ok, %Req.Response{status: 200, body: Jason.encode!(master)}}
      end
    end)
  end

  defp await_requests(count) do
    for _request <- 1..count do
      assert_receive {:request, method, url, body}, @task_timeout
      {method, url, body}
    end
  end

  defp expect_puts(count) do
    test_pid = self()

    expect(Tymeslot.HTTPClientMock, :put, count, fn url, body, _headers, _opts ->
      send(test_pid, {:put, url, body})
      {:ok, %Req.Response{status: 204, body: "", headers: %{}}}
    end)
  end

  defp await_puts(count) do
    for _put <- 1..count do
      assert_receive {:put, url, body}, @task_timeout
      {url, body}
    end
  end
end
