defmodule Tymeslot.Workers.AccountDeletionWorker do
  @moduledoc """
  Deletes one account once its deletion is due; the work itself is
  `Tymeslot.Auth.AccountDeletion.Runner`. Queued for `deletion_scheduled_at`
  when a deletion is requested, and again by the daily sweep for an overdue
  account whose job was lost or discarded.

  Unique per user while a job is waiting or running, so a double submit or a
  sweep never queues a second one; a restore deletes the waiting job. A
  refusal from the deletion hook (billing unreachable, say) is retried with
  Oban's backoff, and once the attempts run out the sweep tries again the
  next day.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 5,
    unique: [period: :infinity, keys: [:user_id], states: :incomplete]

  alias Tymeslot.Auth

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id}}) when is_integer(user_id) do
    case Auth.run_scheduled_deletion(user_id) do
      {:ok, _outcome} -> :ok
      {:snooze, seconds} -> {:snooze, seconds}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Queues the deletion of `user_id` for `at`."
  @spec schedule(pos_integer(), DateTime.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def schedule(user_id, %DateTime{} = at) do
    %{"user_id" => user_id}
    |> new(scheduled_at: at)
    |> Oban.insert()
  end
end
