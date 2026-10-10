defmodule Tymeslot.Workers.EmailWorkerHandlers do
  @moduledoc """
  Internal handlers for EmailWorker actions.
  """

  alias Tymeslot.Emails.EmailActions
  alias Tymeslot.Workers.EmailWorkerHandlers.AuthEmails
  alias Tymeslot.Workers.EmailWorkerHandlers.BookingApprovalEmails
  alias Tymeslot.Workers.EmailWorkerHandlers.EndChangeEmails
  alias Tymeslot.Workers.EmailWorkerHandlers.GroupMeetingEmails
  alias Tymeslot.Workers.EmailWorkerHandlers.GuestEmails
  alias Tymeslot.Workers.EmailWorkerHandlers.IntegrationEmails
  alias Tymeslot.Workers.EmailWorkerHandlers.MeetingEmails
  alias Tymeslot.Workers.EmailWorkerHandlers.PollEmails
  alias Tymeslot.Workers.EmailWorkerHandlers.RescheduleEmails
  alias Tymeslot.Workers.EmailWorkerHandlers.SeatJobs

  # The handlers that declare some of their discards an expected end of the
  # job. `AdminEmails` discards nothing of its own.
  @declaring_handlers [
    AuthEmails,
    BookingApprovalEmails,
    EndChangeEmails,
    GroupMeetingEmails,
    GuestEmails,
    IntegrationEmails,
    MeetingEmails,
    PollEmails,
    RescheduleEmails,
    SeatJobs
  ]

  @doc """
  Whether `reason`, from a discard one of the handlers returned, is an
  expected end of the email job rather than a fault
  (see `Tymeslot.Infrastructure.ExpectedJobOutcome`).
  """
  @spec expected_discard?(term()) :: boolean()
  def expected_discard?(reason),
    do: Enum.any?(@declaring_handlers, & &1.expected_discard?(reason))

  @doc """
  Executes the specified email action with the given arguments.

  This is the primary entry point for the EmailWorker to process various types of
  email jobs, including confirmations, reminders, and authentication emails.

  Returns `:ok` on success, `{:error, reason}` for retriable failures,
  `{:discard, reason}` for fatal errors that shouldn't be retried,
  or `{:snooze, seconds}` if the job should be delayed.

  `job_id` is the id of the Oban job running the action, or `nil` for a job
  that was never persisted (which cannot be rescued, so needs no guard).
  """
  @spec execute_email_action(String.t(), %{String.t() => term()}, integer() | nil) ::
          :ok | {:error, term()} | {:discard, String.t()} | {:snooze, integer()}
  def execute_email_action(action, args, job_id \\ nil) do
    case EmailActions.handler(action) do
      {:ok, {module, fun}} -> apply(module, fun, [args])
      {:ok, {module, fun, :with_job_id}} -> apply(module, fun, [args, job_id])
      :error -> {:discard, "Unknown action: #{action}"}
    end
  end
end
