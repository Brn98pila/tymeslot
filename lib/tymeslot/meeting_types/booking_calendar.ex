defmodule Tymeslot.MeetingTypes.BookingCalendar do
  @moduledoc """
  The calendar a meeting type books into must block availability, so a
  meeting-type write that names one makes it block first, in the same
  transaction and before the meeting type's own row is written: the
  integration's row is locked ahead of the meeting type's, the order
  `Tymeslot.Integrations.Calendar.Blocking` documents.
  """

  alias Ecto.Changeset
  alias Tymeslot.Integrations.Calendar.Blocking

  @doc """
  Makes the booking calendar `changeset` names block, when the write changes
  which calendar that is. Call it inside the meeting type's transaction,
  before the write. `{:ok, :promoted | :unchanged}`, or `{:error, reason}`
  to roll the write back.
  """
  @spec promote(Changeset.t()) :: {:ok, :promoted | :unchanged} | {:error, term()}
  def promote(%Changeset{} = changeset) do
    user_id = Changeset.get_field(changeset, :user_id)
    integration_id = Changeset.get_field(changeset, :calendar_integration_id)
    calendar_id = Changeset.get_field(changeset, :target_calendar_id)

    retargeted? =
      Changeset.changed?(changeset, :calendar_integration_id) or
        Changeset.changed?(changeset, :target_calendar_id)

    if retargeted? and is_integer(user_id) and is_integer(integration_id) and
         is_binary(calendar_id) do
      Blocking.promote_booking_target(user_id, integration_id, calendar_id)
    else
      {:ok, :unchanged}
    end
  end
end
