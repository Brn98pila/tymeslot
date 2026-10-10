defmodule Tymeslot.Emails.Templates.RecipientTimeZoneTest do
  @moduledoc """
  Each recipient of a booking's emails reads the meeting's time on their own
  clock, in both parts of the email: the organiser in the organiser's zone,
  the booker and their guests in the booker's. The HTML card and the plain-text
  body state the same time, labelled with the same zone.

  The organiser is in Berlin and the booker in Kolkata, a half-hour offset, so
  a time taken from the wrong side cannot coincide with the right one.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :emails

  import Tymeslot.EmailTestHelpers

  alias Tymeslot.Emails.Templates.{
    AppointmentCancellation,
    AppointmentConfirmation,
    AppointmentReminder,
    AppointmentRescheduled
  }

  # 09:00 UTC on 15 January: 10:00 in Berlin (CET), 14:30 in Kolkata (IST).
  @start ~U[2026-01-15 09:00:00Z]

  @organizer_time "10:00 CET (Europe/Berlin)"
  @attendee_time_en "02:30 PM IST (Asia/Kolkata)"
  @attendee_time_de "14:30 IST (Asia/Kolkata)"

  defp details(overrides \\ %{}) do
    build_appointment_details(
      Map.merge(
        %{
          start_time: @start,
          end_time: DateTime.add(@start, 60, :minute),
          start_time_owner_tz: DateTime.shift_zone!(@start, "Europe/Berlin"),
          start_time_attendee_tz: DateTime.shift_zone!(@start, "Asia/Kolkata"),
          owner_timezone: "Europe/Berlin",
          attendee_timezone: "Asia/Kolkata",
          organizer_locale: "en",
          organizer_time_format: "24h",
          guest_name: "Greg Guest"
        },
        overrides
      )
    )
  end

  # The time line is the same in both parts; the HTML escapes nothing in it.
  defp assert_reads(email, time) do
    assert email.html_body =~ time
    assert email.text_body =~ "Time: #{time}"
  end

  for template <- [
        AppointmentConfirmation,
        AppointmentReminder,
        AppointmentCancellation,
        AppointmentRescheduled
      ] do
    describe "#{inspect(template)}" do
      test "the organiser reads their own time and zone in HTML and text" do
        email = unquote(template).render(:organizer, "organizer@example.com", details())

        assert_reads(email, @organizer_time)
        refute email.text_body =~ "Asia/Kolkata"
        refute email.text_body =~ "IST"
      end

      test "the booker reads their own time and zone in HTML and text" do
        email = unquote(template).render(:attendee, "attendee@example.com", details())

        assert_reads(email, @attendee_time_en)
        refute email.text_body =~ "Europe/Berlin"
      end

      test "a guest reads the booker's time and zone in HTML and text" do
        email = unquote(template).render(:guest, "greg@example.com", details())

        assert_reads(email, @attendee_time_en)
      end

      test "a German booker reads their time on their own clock" do
        email =
          unquote(template).render(
            :attendee,
            "attendee@example.com",
            details(%{attendee_locale: "de"})
          )

        assert email.html_body =~ @attendee_time_de
        assert email.text_body =~ "Uhrzeit: #{@attendee_time_de}"
      end
    end
  end

  test "a payload without the booker's zone still renders their time, unlabelled" do
    email =
      AppointmentCancellation.render(
        :attendee,
        "attendee@example.com",
        Map.delete(details(), :attendee_timezone)
      )

    assert email.html_body =~ "02:30 PM IST"
    assert email.text_body =~ "Time: 02:30 PM IST\n"
  end
end
