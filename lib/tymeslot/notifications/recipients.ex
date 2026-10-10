defmodule Tymeslot.Notifications.Recipients do
  @moduledoc """
  Determines who should receive notifications and their context.
  Pure functions for recipient determination and notification targeting.
  """

  require Logger

  alias Tymeslot.Emails.HostClock
  alias Tymeslot.Meetings

  @typep participant :: %{
           required(:email) => String.t() | nil,
           required(:name) => String.t() | nil,
           required(:timezone) => String.t()
         }

  @doc """
  Determines the recipients of a meeting's notifications.

  Routing depends on the meeting alone, so every notification type routes the
  same way. A group meeting routes to the organizer only (see
  `recipients_for/2`).
  """
  @spec determine_recipients(term()) ::
          {:both | :organizer_only,
           %{
             required(:organizer) => participant(),
             required(:attendee) => participant()
           }}
  def determine_recipients(meeting) do
    recipients_for(meeting, base_recipients(meeting))
  end

  defp base_recipients(meeting) do
    %{
      organizer: %{
        email: meeting.organizer_email,
        name: meeting.organizer_name,
        timezone: get_organizer_timezone(meeting)
      },
      attendee: %{
        email: meeting.attendee_email,
        name: meeting.attendee_name,
        timezone: meeting.attendee_timezone || get_organizer_timezone(meeting)
      }
    }
  end

  # A group meeting's row carries no attendee of its own — `attendee_email`,
  # `attendee_name` and `attendee_timezone` are nullable precisely because
  # group attendees live on `meeting_participants`, not on the meeting row.
  # The organizer is still a real recipient; the meeting-row "attendee" is
  # not, so validation must not demand fields that cannot exist. Participants
  # are resolved and emailed downstream via `Meetings.recipients/1`.
  defp recipients_for(meeting, base_recipients) do
    if Meetings.group?(meeting) do
      {:organizer_only, base_recipients}
    else
      {:both, base_recipients}
    end
  end

  @doc """
  Gets the organizer's timezone from their profile.
  Requires the meeting to have organizer_user_id set.
  """
  @spec get_organizer_timezone(term()) :: String.t()
  def get_organizer_timezone(%{organizer_user_id: nil} = meeting) do
    Logger.error("Missing organizer_user_id for meeting; using default timezone",
      meeting_id: Map.get(meeting, :id)
    )

    HostClock.timezone(meeting)
  end

  def get_organizer_timezone(meeting), do: HostClock.timezone(meeting)

  @doc """
  Gets the attendee's timezone from the meeting record.
  The attendee_timezone should always be populated during booking creation.
  """
  @spec get_attendee_timezone(term()) :: String.t()
  # A group meeting's row never carries an attendee (its people are its
  # participants), so a missing timezone there is the design, not a defect
  # worth a warning on every booking.
  def get_attendee_timezone(%{attendee_timezone: nil, capacity: capacity} = meeting)
      when is_integer(capacity) and capacity > 1,
      do: get_organizer_timezone(meeting)

  def get_attendee_timezone(meeting) do
    # This should always be set, but add defensive logging
    case meeting.attendee_timezone do
      nil ->
        require Logger

        Logger.warning(
          "Missing attendee_timezone for meeting; using organizer timezone as emergency fallback",
          meeting_id: Map.get(meeting, :id)
        )

        get_organizer_timezone(meeting)

      timezone ->
        timezone
    end
  end

  @doc """
  Validates that recipient information is complete.
  """
  @spec validate_recipients(term()) :: :ok | {:error, String.t()}
  def validate_recipients(recipients) do
    case recipients do
      {:both, %{organizer: organizer, attendee: attendee}} ->
        with :ok <- validate_recipient(organizer, :organizer) do
          validate_recipient(attendee, :attendee)
        end

      {:organizer_only, %{organizer: organizer}} ->
        validate_recipient(organizer, :organizer)

      _invalid_structure ->
        {:error, "Invalid recipient structure"}
    end
  end

  # Private functions

  defp validate_recipient(recipient, type) do
    required_fields = [:email, :name, :timezone]

    missing_fields =
      Enum.reject(required_fields, fn field ->
        Map.has_key?(recipient, field) and recipient[field]
      end)

    case missing_fields do
      [] -> :ok
      fields -> {:error, "Missing #{type} fields: #{Enum.join(fields, ", ")}"}
    end
  end
end
