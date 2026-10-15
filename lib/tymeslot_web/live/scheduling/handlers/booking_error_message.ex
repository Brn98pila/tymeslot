defmodule TymeslotWeb.Live.Scheduling.Handlers.BookingErrorMessage do
  @moduledoc """
  Renders `Tymeslot.Bookings.Errors.classified_error/0` reasons, the
  `Tymeslot.Bookings.Policy` and `Tymeslot.Bookings.Validation` refusals
  among them, into user-facing flash copy — display copy is a
  presentation-layer concern, not baked into the domain contract.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  @doc """
  Renders a booking error reason to user-facing flash text.

  Unknown reasons fall back to a generic message rather than leaking
  internals.
  """
  @spec message(term()) :: String.t()
  def message(:slot_taken) do
    dgettext(
      "booking",
      "This time slot is no longer available. Please select a different time."
    )
  end

  def message(:availability_unverifiable) do
    dgettext(
      "booking",
      "We couldn't check the host's calendar right now. Please try again in a few minutes."
    )
  end

  def message(:booking_limit_reached) do
    dgettext(
      "booking",
      "The host is no longer accepting bookings for this period. Please pick a different day."
    )
  end

  def message(:meeting_type_inactive) do
    dgettext("booking", "This meeting type is no longer available. Please refresh the page.")
  end

  def message(:meeting_type_not_found) do
    dgettext(
      "booking",
      "This meeting type is no longer available. Please go back and select another."
    )
  end

  def message(:organizer_required) do
    dgettext("booking", "Organiser is required for booking")
  end

  def message(:booking_failed) do
    dgettext("booking", "Failed to save meeting to database")
  end

  def message(:payments_unavailable) do
    dgettext(
      "booking",
      "Payments are not available for this booking. Please contact the host."
    )
  end

  def message(:host_not_found) do
    dgettext("booking", "Host could not be found. Please refresh and try again.")
  end

  def message(:custom_field_errors) do
    dgettext("booking", "Please fill in all required fields before submitting.")
  end

  def message(:checkout_failed) do
    dgettext("booking", "We couldn't start the payment process. Please try again.")
  end

  def message(:failed_to_update_meeting) do
    dgettext("booking", "Failed to process booking. Please try again.")
  end

  def message(:meeting_not_found) do
    dgettext("booking", "This meeting could not be found. Please refresh and try again.")
  end

  def message(:already_booked) do
    dgettext(
      "booking",
      "You already have a spot at this time. Check your email for your booking confirmation."
    )
  end

  def message(:already_cancelled) do
    dgettext("booking", "This booking has already been cancelled or moved.")
  end

  def message(:group_meeting_not_reschedulable) do
    dgettext(
      "booking",
      "This is a group booking, so each participant moves their own spot from their confirmation email."
    )
  end

  def message(:seat_not_movable) do
    dgettext(
      "booking",
      "This spot can no longer be moved. Cancel it and book a new time instead, or contact the host."
    )
  end

  def message(:seat_time_unchanged) do
    dgettext("booking", "This is your current time. Pick a different time to move your spot.")
  end

  # Step-requirement refusals: the booker has not chosen enough yet to move on.
  # `Availability.Calculate` and `MeetingTypes.Duration` used to return this
  # copy themselves, in English, straight into a flash on a public multi-locale
  # page.
  def message(:duration_required) do
    dgettext("booking", "Please select a meeting duration")
  end

  def message(:duration_invalid) do
    dgettext("booking", "Invalid meeting duration selected")
  end

  def message(:date_required) do
    dgettext("booking", "Please select a date")
  end

  def message(:time_required) do
    dgettext("booking", "Please select a time")
  end

  def message(:selection_required) do
    dgettext("booking", "Please select a date and time")
  end

  # Refusals from the booking rules (`Policy`, `Validation`, `CreateAdHoc`).
  def message({:not_cancellable, :completed}),
    do: dgettext("booking", "Cannot cancel a completed meeting")

  def message({:not_cancellable, :expired}),
    do: dgettext("booking", "Cannot cancel an expired meeting")

  def message({:not_cancellable, :started}),
    do: dgettext("booking", "Cannot cancel a meeting that has already started")

  def message({:not_cancellable, :past}),
    do: dgettext("booking", "Cannot cancel a meeting that has already occurred")

  def message({:not_reschedulable, :cancelled}),
    do: dgettext("booking", "Cannot reschedule a cancelled meeting")

  def message({:not_reschedulable, :completed}),
    do: dgettext("booking", "Cannot reschedule a completed meeting")

  def message({:not_reschedulable, :expired}),
    do: dgettext("booking", "Cannot reschedule an expired meeting")

  def message({:not_reschedulable, :started}),
    do: dgettext("booking", "Cannot reschedule a meeting that has already started")

  def message({:not_reschedulable, :past}),
    do: dgettext("booking", "Cannot reschedule a meeting that has already occurred")

  def message({:not_reschedulable, :awaiting_approval}),
    do: dgettext("booking", "Cannot request a reschedule while the booking awaits approval")

  # Reuses the msgid `localization_helpers.ex` already defines (and every
  # locale already translates) for the same problem.
  def message(:invalid_datetime), do: dgettext("booking", "Invalid date/time")

  def message(:in_past), do: dgettext("booking", "Booking time must be in the future")

  def message({:too_soon, hours}),
    do: dgettext("booking", "Booking requires at least %{hours} hours in advance", hours: hours)

  def message({:too_far_ahead, days}),
    do: dgettext("booking", "You cannot book more than %{days} days in advance", days: days)

  def message(:title_required), do: dgettext("booking", "Title is required")
  def message(:attendee_name_required), do: dgettext("booking", "Attendee name is required")
  def message(:attendee_email_required), do: dgettext("booking", "Attendee email is required")

  def message(:attendee_is_organizer),
    do: dgettext("booking", "The guest email must differ from your own address")

  def message(:end_before_start), do: dgettext("booking", "End time must be after start time")
  def message(:meeting_creation_failed), do: dgettext("booking", "Failed to create meeting")

  def message(_other), do: unrecognised_message()

  @doc """
  Like `message/1`, but a reason it does not recognise renders `fallback`
  instead of the booking-specific generic message, for callers outside the
  booking submission (cancelling, rescheduling) whose generic failure reads
  differently.
  """
  @spec message(term(), String.t()) :: String.t()
  def message(reason, fallback) do
    unrecognised = unrecognised_message()

    case message(reason) do
      ^unrecognised -> fallback
      rendered -> rendered
    end
  end

  defp unrecognised_message do
    dgettext("booking", "Failed to create appointment. Please try again.")
  end
end
