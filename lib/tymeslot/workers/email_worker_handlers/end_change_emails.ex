defmodule Tymeslot.Workers.EmailWorkerHandlers.EndChangeEmails do
  @moduledoc """
  Sends the notices for a booking whose end the host moved in their own
  calendar (`Tymeslot.Meetings.ExternalCalendarChanges.apply_end_change/2`).
  The booker, or every live participant of a group meeting, and every guest
  get the new end with an updated calendar entry. The host is then told who
  was notified.

  The job waits a little before it runs and carries the end the attendees
  last heard of (`EndChangeScheduler.schedule_end_change_emails/2`), so the
  notice announces the meeting as it stands when the job runs, and a host
  dragging the end several times sends one notice. An end moved back to
  where it was announces nothing.

  Each send is claimed on the job (`DeliveryClaims`), so a retry writes only
  to whoever was missed. A transient failure retries the job; an address the
  provider rejects for good is not retried. The host's notice goes out once
  nobody is left to retry and at least one attendee or guest was reached:
  when nobody was, the host is not told that they were.

  Chat channels and webhooks are not told: the booking did not move.
  """

  require Logger

  alias Tymeslot.Auth
  alias Tymeslot.Clock
  alias Tymeslot.Emails.AppointmentBuilder
  alias Tymeslot.Emails.Delivery
  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.GuestQueries
  alias Tymeslot.Meetings.MeetingState
  alias Tymeslot.Meetings.Recipient
  alias Tymeslot.Notifications.GuestNotifications
  alias Tymeslot.Workers.DeliveryClaims
  alias Tymeslot.Workers.EmailWorkerHandlers.MeetingEmails

  @not_confirmed "Meeting not confirmed"
  @slot_void "Meeting time no longer holds"
  @meeting_started "Meeting already started"
  @end_restored "Meeting end back where it was"
  @host_leaving "Host account pending deletion"

  @doc """
  Whether `reason`, from a discard this module returned, is an expected end
  of the email job rather than a fault
  (see `Tymeslot.Infrastructure.ExpectedJobOutcome`).
  """
  @spec expected_discard?(term()) :: boolean()
  def expected_discard?(reason),
    do: reason in [@not_confirmed, @slot_void, @meeting_started, @end_restored, @host_leaving]

  @doc """
  Sends the notices for the end change the job announces, unless the booking
  has moved on since: no longer confirmed, its time voided, already started,
  its end moved back, or its host leaving.
  """
  @spec handle_end_change_emails(%{String.t() => term()}, DeliveryClaims.job_id()) ::
          :ok | {:error, term()} | {:discard, String.t()}
  def handle_end_change_emails(
        %{"meeting_id" => meeting_id, "previous_end" => previous_end},
        job_id
      ) do
    {:ok, previous_end, _offset} = DateTime.from_iso8601(previous_end)

    MeetingEmails.with_meeting(meeting_id, "end change emails", fn meeting ->
      case overtaken(meeting, previous_end) do
        nil ->
          send_notices(meeting, previous_end, &DeliveryClaims.once(job_id, &1, &2))

        reason ->
          Logger.info("Skipping end change emails overtaken by a later change",
            meeting_id: meeting_id,
            reason: reason
          )

          {:discard, reason}
      end
    end)
  end

  defp overtaken(meeting, previous_end) do
    cond do
      meeting.status != "confirmed" -> @not_confirmed
      MeetingState.slot_void?(meeting) -> @slot_void
      not DateTime.after?(meeting.start_time, Clock.utc_now()) -> @meeting_started
      DateTime.compare(meeting.end_time, previous_end) == :eq -> @end_restored
      host_leaving?(meeting) -> @host_leaving
      true -> nil
    end
  end

  defp host_leaving?(%{organizer_user_id: user_id}) when is_integer(user_id),
    do: Auth.deletion_pending?(user_id)

  defp host_leaving?(_meeting), do: false

  defp send_notices(meeting, previous_end, once) do
    outcomes =
      attendee_outcomes(meeting, previous_end, once) ++
        guest_outcomes(meeting, previous_end, once)

    cond do
      Enum.any?(outcomes, &match?({:failed, _who}, &1)) ->
        {:error, "End change notices failed for some recipients"}

      Enum.any?(outcomes, &match?({:sent, _who}, &1)) ->
        notify_host(meeting, previous_end, outcomes, once)

      true ->
        Logger.warning("End change reached no attendee; the host is not told it did",
          meeting_id: meeting.id
        )

        :ok
    end
  end

  # The booker of a solo meeting, or each live participant of a group one,
  # with the meeting rendered as they see it (their own seat's calendar
  # entry, for a participant).
  defp attendee_outcomes(meeting, previous_end, once) do
    for recipient <- Meetings.recipients(meeting) do
      details =
        meeting
        |> AppointmentBuilder.from_meeting(recipient, nil)
        |> with_previous_end(previous_end)

      result =
        once.("end_change:#{recipient_key(recipient)}", fn ->
          Config.email_service_module().send_end_change_to_attendee(recipient.email, details)
        end)

      outcome(result, {recipient.kind, recipient.name || recipient.email}, meeting)
    end
  end

  defp guest_outcomes(meeting, previous_end, once) do
    fallback = AppointmentBuilder.from_meeting(meeting)

    meeting.id
    |> GuestQueries.list_live_for_meeting()
    |> GuestNotifications.with_inviter_details(meeting, fallback)
    |> Enum.map(fn {guest, details} ->
      details =
        details
        |> with_previous_end(previous_end)
        |> GuestNotifications.guest_details(guest)

      result =
        once.("end_change:guest:#{guest.id}", fn ->
          Config.email_service_module().send_guest_end_change(guest.email, details)
        end)

      outcome(result, {:guest, guest.name || guest.email}, meeting)
    end)
  end

  defp recipient_key(%Recipient{kind: :participant, participant_id: id}), do: "participant:#{id}"
  defp recipient_key(%Recipient{}), do: "attendee"

  # The template reads it in the recipient's zone, as it reads the start.
  defp with_previous_end(details, previous_end),
    do: Map.put(details, :original_end_time, previous_end)

  # A claim an earlier run made (`:ok`) is a send that went out.
  defp outcome(:ok, who, _meeting), do: {:sent, who}
  defp outcome({:ok, _result}, who, _meeting), do: {:sent, who}

  defp outcome({:error, reason}, who, meeting) do
    if Delivery.permanent_rejection?(reason) do
      Logger.warning("End change notice rejected for good",
        meeting_id: meeting.id,
        recipient_kind: elem(who, 0)
      )

      {:rejected, who}
    else
      Logger.error("End change notice failed",
        meeting_id: meeting.id,
        recipient_kind: elem(who, 0),
        reason: LogFormat.reason(reason)
      )

      {:failed, who}
    end
  end

  defp notify_host(meeting, previous_end, outcomes, once) do
    reached = for {:sent, who} <- outcomes, do: who

    notice = %{
      previous_end_time: previous_end,
      attendees: for({kind, name} <- reached, kind != :guest, do: name),
      guests: Enum.count(reached, &match?({:guest, _name}, &1))
    }

    result =
      once.("end_change:host", fn ->
        Config.email_service_module().send_end_change_to_organizer(
          meeting,
          meeting.organizer_email,
          notice
        )
      end)

    case outcome(result, {:organizer, meeting.organizer_name}, meeting) do
      {:failed, _who} -> {:error, "End change notice to the host failed"}
      _sent_or_rejected -> :ok
    end
  end
end
