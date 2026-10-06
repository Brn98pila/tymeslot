defmodule Tymeslot.Emails.HostClock do
  @moduledoc """
  The clock a host reads their booking emails by: their timezone and their
  chosen 12- or 24-hour format.

  Resolved once per email from the meeting's organiser, for the
  host-addressed templates that render straight from a meeting rather than
  from `Tymeslot.Emails.AppointmentBuilder`'s payload (which carries the same
  two values as `:owner_timezone` and `:organizer_time_format`). An
  organiser-less meeting reads in the platform default timezone and the
  locale's own clock.
  """

  alias Tymeslot.CalendarGrid
  alias Tymeslot.Profiles

  @type t :: %{timezone: String.t(), time_format: String.t() | nil}

  @doc """
  The host clock for `meeting`'s organiser. `locale` is the email's, which
  decides the clock when the host never chose one.
  """
  @spec for_meeting(map(), String.t()) :: t()
  def for_meeting(%{organizer_user_id: nil}, _locale),
    do: %{timezone: Profiles.get_default_timezone(), time_format: nil}

  def for_meeting(%{organizer_user_id: user_id}, locale) do
    %{
      timezone: Profiles.get_user_timezone(user_id),
      time_format: CalendarGrid.get_user_time_format(user_id, locale)
    }
  end
end
