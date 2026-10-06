defmodule Tymeslot.Workers.EmailWorkerHandlers.RescheduleEmails do
  @moduledoc """
  Sends the notices for a booking that moved: to the organiser, the attendee
  and every guest, each with an updated calendar entry.

  Two moves end here (`Tymeslot.Notifications.Orchestrator` validates and
  enqueues both):

    * a reschedule, whose job carries the time it moved from (`"original"`),
      since the meeting row no longer has it, so the emails can show both;
    * a booking whose new time the host has just approved after a reschedule
      sent it back into the approval gate (no `"original"`): the time it
      moved from is gone by then, so these notices carry the new time alone,
      and only the guests who had been invited are written to.

  Sends are claimed on the job (`DeliveryClaims`), as for a cancellation: one
  claim for the organiser and attendee pair, which the email service sends
  in one call, and one per guest, so a rescued run repeats nothing already
  sent. When both participant emails fail the job retries, and an open mail
  circuit snoozes it, as for every other booking email; a partial send is
  discarded rather than duplicated. Guest sends are logged and never fail the
  job, as everywhere else.
  """

  require Logger

  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Notifications.ContentBuilder
  alias Tymeslot.Notifications.GuestNotifications
  alias Tymeslot.Workers.DeliveryClaims
  alias Tymeslot.Workers.EmailWorkerHandlers.DeliveryOutcome
  alias Tymeslot.Workers.EmailWorkerHandlers.MeetingEmails

  # The same reason `MeetingEmails` gives, so it counts as an expected end of
  # the job there.
  @meeting_cancelled "Meeting cancelled"

  @spec handle_reschedule_emails(%{String.t() => term()}, DeliveryClaims.job_id()) ::
          :ok | {:error, term()} | {:discard, String.t()}
  def handle_reschedule_emails(%{"meeting_id" => meeting_id} = args, job_id) do
    MeetingEmails.with_meeting(meeting_id, "reschedule emails", fn meeting ->
      if meeting.status == "cancelled" do
        Logger.info("Skipping reschedule emails for cancelled meeting", meeting_id: meeting_id)
        {:discard, @meeting_cancelled}
      else
        send_reschedule_emails(meeting, Map.get(args, "original"), job_id)
      end
    end)
  end

  defp send_reschedule_emails(meeting, original, job_id) do
    content = content(meeting, original)
    once = &DeliveryClaims.once(job_id, &1, &2)

    result =
      once.("reschedule:participants", fn ->
        {organizer_result, attendee_result} =
          Config.email_service_module().send_reschedule_emails(content)

        DeliveryOutcome.from_dual_send(
          "reschedule",
          [meeting_id: meeting.id],
          organizer_result,
          attendee_result
        )
      end)

    # As for a cancellation: guests are told whenever at least one
    # participant email went out, even on a partial failure that is discarded
    # rather than retried, so they are told now or never.
    if result == :ok or match?({:discard, _reason}, result),
      do: notify_guests(meeting, content, original, once)

    result
  end

  defp notify_guests(meeting, content, nil, once),
    do: GuestNotifications.notify_reapproved(meeting, content, once)

  defp notify_guests(meeting, content, _original, once),
    do: GuestNotifications.notify_rescheduled(meeting, content, once)

  defp content(meeting, nil), do: ContentBuilder.build_reapproval_details(meeting)

  defp content(meeting, original) do
    ContentBuilder.build_reschedule_details(meeting, %{
      start_time: parse_datetime(original["start_time"]),
      end_time: parse_datetime(original["end_time"]),
      attendee_video_url: original["attendee_video_url"]
    })
  end

  defp parse_datetime(iso) when is_binary(iso) do
    {:ok, datetime, _offset} = DateTime.from_iso8601(iso)
    datetime
  end
end
