defmodule Tymeslot.Auth.AccountDeletion.Runner do
  @moduledoc """
  What the deletion job does for one account, and the daily sweep that
  re-queues overdue accounts whose job was lost or gave up.

  For an account still pending and due, in this order:

    1. third-party cleanup (`ExternalCleanup`), while its credentials exist;
    2. the meeting ids, read before the cascade removes the meetings;
    3. `AccountDeletion.delete_account/2` with `only_if_pending: true`: the
       deletion hook (whose refusal makes the job retry), then one
       transaction that re-checks the account is still pending under a row
       lock and deletes it;
    4. every pending job naming the user or one of those meetings, so no
       reminder outlives the account with a guest's address in its args.

  Guests are never told: no cancellation email, webhook, Slack or Telegram
  message goes out for the meetings this removes.
  """

  require Logger

  alias Tymeslot.Auth.AccountDeletion
  alias Tymeslot.Auth.AccountDeletion.ExternalCleanup
  alias Tymeslot.Auth.{UserQueries, UserSchema}
  alias Tymeslot.Jobs
  alias Tymeslot.Meetings
  alias Tymeslot.Workers.AccountDeletionWorker

  @sweep_batch_size 500

  @type outcome ::
          {:ok, :deleted | :already_deleted | :not_pending}
          | {:snooze, pos_integer()}
          | {:error, term()}

  @spec run(integer()) :: outcome()
  def run(user_id) when is_integer(user_id) do
    case UserQueries.get_user(user_id) do
      {:error, :not_found} -> {:ok, :already_deleted}
      {:ok, %UserSchema{deletion_scheduled_at: nil}} -> {:ok, :not_pending}
      {:ok, %UserSchema{} = user} -> run_when_due(user, DateTime.utc_now())
    end
  end

  defp run_when_due(%UserSchema{deletion_scheduled_at: due_at} = user, now) do
    case DateTime.compare(due_at, now) do
      :gt -> {:snooze, max(DateTime.diff(due_at, now), 1)}
      _due -> hard_delete(user)
    end
  end

  defp hard_delete(user) do
    ExternalCleanup.run(user)
    meeting_ids = Meetings.list_meeting_ids_for_organizer(user.id)

    case AccountDeletion.delete_account(user, only_if_pending: true) do
      {:ok, _deleted} ->
        Jobs.delete_pending_account_jobs(user.id, meeting_ids)
        Logger.info("Account deleted", user_id: user.id)
        {:ok, :deleted}

      {:error, :not_pending} ->
        {:ok, :not_pending}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Queues a deletion job for every overdue account, at most
  #{@sweep_batch_size} per run. An account whose job is still waiting gets no
  second one (the worker is unique per user). Returns how many were queued.
  """
  @spec enqueue_overdue(DateTime.t()) :: non_neg_integer()
  def enqueue_overdue(now \\ DateTime.utc_now()) do
    now
    |> UserQueries.list_due_deletion_ids(@sweep_batch_size)
    |> Enum.count(fn user_id ->
      match?({:ok, %Oban.Job{conflict?: false}}, AccountDeletionWorker.schedule(user_id, now))
    end)
  end
end
