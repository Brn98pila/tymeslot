defmodule Tymeslot.Emails.EmailScheduler.EndChangeScheduler do
  @moduledoc "Schedules the notices of a booking whose end the host moved in their own calendar."

  alias Tymeslot.Emails.EmailScheduler.Helpers
  alias Tymeslot.Workers.EmailWorker

  # A host dragging an end several times sends one notice, with the last end.
  @end_change_settle_seconds 120

  @doc """
  Schedules the notices of a booking whose end the host moved in their own
  calendar (`Tymeslot.Workers.EmailWorkerHandlers.EndChangeEmails`). One job
  waits per meeting; a change while it waits keeps its `previous_end` (the
  end the attendees last heard of) and moves it back by the settling delay.
  """
  @spec schedule_end_change_emails(String.t(), DateTime.t()) :: :ok | {:error, String.t()}
  def schedule_end_change_emails(meeting_id, %DateTime{} = previous_end) do
    %{
      "action" => "send_end_change_emails",
      "meeting_id" => meeting_id,
      "previous_end" => DateTime.to_iso8601(previous_end)
    }
    |> EmailWorker.new(
      queue: :emails,
      priority: 1,
      schedule_in: @end_change_settle_seconds,
      unique: [
        period: :infinity,
        fields: [:args, :queue],
        keys: [:action, :meeting_id],
        states: [:scheduled]
      ],
      replace: [scheduled: [:scheduled_at]]
    )
    |> Helpers.insert_job("End change emails", meeting_id)
  end
end
