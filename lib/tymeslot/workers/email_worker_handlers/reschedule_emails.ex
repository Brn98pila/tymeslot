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

  alias Tymeslot.Clock
  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Meetings.MeetingState
  alias Tymeslot.Notifications.ContentBuilder
  alias Tymeslot.Notifications.GuestNotifications
  alias Tymeslot.Workers.DeliveryClaims
  alias Tymeslot.Workers.EmailWorkerHandlers.DeliveryOutcome
  alias Tymeslot.Workers.EmailWorkerHandlers.MeetingEmails

  # A notice overtaken by events since the move it announces. The cancelled
  # reason is the one `MeetingEmails` gives, the void-slot one the one
  # `SeatJobs` gives.
  @meeting_cancelled "Meeting cancelled"
  @slot_void "Meeting time no longer holds"
  @moved_again "Meeting moved again"
  @status_changed "Meeting status changed"
  @meeting_started "Meeting already started"

  @doc """
  Whether `reason`, from a discard this module returned, is an expected end
  of the email job rather than a fault
  (see `Tymeslot.Infrastructure.ExpectedJobOutcome`).
  """
  @spec expected_discard?(term()) :: boolean()
  def expected_discard?(reason),
    do:
      reason in [@meeting_cancelled, @slot_void, @moved_again, @status_changed, @meeting_started]

  @doc """
  Sends the notices for the move the job announces, unless the booking has
  moved on since: cancelled, sent back for a new time, moved again (the later
  move's own job tells everyone the time it now has), approved or declined
  into another status, or already started. Each of those discards the job
  rather than sending times nobody should act on.
  """
  @spec handle_reschedule_emails(%{String.t() => term()}, DeliveryClaims.job_id()) ::
          :ok | {:error, term()} | {:discard, String.t()}
  def handle_reschedule_emails(%{"meeting_id" => meeting_id} = args, job_id) do
    MeetingEmails.with_meeting(meeting_id, "reschedule emails", fn meeting ->
      case overtaken(meeting, args) do
        nil ->
          send_reschedule_emails(meeting, Map.get(args, "original"), job_id)

        reason ->
          Logger.info("Skipping reschedule emails overtaken by a later change",
            meeting_id: meeting_id,
            reason: reason
          )

          {:discard, reason}
      end
    end)
  end

  defp overtaken(meeting, args) do
    cond do
      meeting.status == "cancelled" -> @meeting_cancelled
      MeetingState.slot_void?(meeting) -> @slot_void
      moved_again?(meeting, args["rescheduled_to"]) -> @moved_again
      status_changed?(meeting, args["status"]) -> @status_changed
      DateTime.compare(meeting.start_time, Clock.utc_now()) != :gt -> @meeting_started
      true -> nil
    end
  end

  # Jobs enqueued before the move's time and status were carried have
  # neither, and are judged on the rest.
  defp moved_again?(_meeting, nil), do: false

  defp moved_again?(meeting, rescheduled_to),
    do: DateTime.compare(meeting.start_time, parse_datetime(rescheduled_to)) != :eq

  defp status_changed?(_meeting, nil), do: false
  defp status_changed?(meeting, status), do: meeting.status != status

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
