defmodule Tymeslot.Emails.EmailScheduler.Helpers do
  @moduledoc "Shared helpers for EmailScheduler sub-modules."

  alias Ecto.Changeset
  alias Tymeslot.Infrastructure.Logging.LogFormat

  require Logger

  @doc """
  Formats an Oban insert error into a loggable string.
  """
  @spec format_insert_error(term()) :: term()
  def format_insert_error(%Changeset{} = changeset) do
    Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
  end

  def format_insert_error(other), do: LogFormat.reason(other)

  @doc """
  Inserts an email job and logs the outcome. A unique-conflict is success:
  the job we wanted already exists. Oban signals that by returning the
  existing job with `conflict?: true`, not a changeset error; a unique
  constraint never reaches the changeset
  because Oban resolves it with an upsert, so matching on
  `{:error, %Ecto.Changeset{errors: [unique: _]}}` is unreachable and would
  silently misreport a dedup as a fresh schedule.
  """
  @spec insert_job(Ecto.Changeset.t(), String.t(), term(), keyword()) ::
          :ok | {:error, String.t()}
  def insert_job(changeset, label, meeting_id, extra_meta \\ []) do
    case Oban.insert(changeset) do
      {:ok, %Oban.Job{conflict?: true}} ->
        Logger.info(
          "Approval email job already exists, skipping duplicate",
          [meeting_id: meeting_id, email_job: label] ++ extra_meta
        )

        :ok

      {:ok, _job} ->
        Logger.info(
          "Approval email job scheduled",
          [meeting_id: meeting_id, email_job: label] ++ extra_meta
        )

        :ok

      {:error, reason} ->
        Logger.error(
          "Failed to schedule approval email job",
          [meeting_id: meeting_id, email_job: label, error: format_insert_error(reason)] ++
            extra_meta
        )

        {:error, "Failed to schedule job"}
    end
  end
end
