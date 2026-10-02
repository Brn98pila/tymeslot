defmodule Tymeslot.Workers.AccountDeletionWorkerTest do
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :workers
  @moduletag :auth

  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.Repo
  alias Tymeslot.Workers.{AccountDeletionSweepWorker, AccountDeletionWorker}

  setup do
    with_config(:tymeslot, :account_deletion_hook, nil)
    :ok
  end

  test "deletes a due account" do
    at = DateTime.add(DateTime.utc_now(:second), -1, :second)
    user = insert(:user, deletion_requested_at: at, deletion_scheduled_at: at)

    assert perform_job(AccountDeletionWorker, %{"user_id" => user.id}) == :ok
    refute Repo.get(UserSchema, user.id)
  end

  test "snoozes until the account is due" do
    at = DateTime.add(DateTime.utc_now(:second), 1, :day)
    user = insert(:user, deletion_requested_at: at, deletion_scheduled_at: at)

    assert {:snooze, _seconds} = perform_job(AccountDeletionWorker, %{"user_id" => user.id})
  end

  test "is unique per user while a job is waiting" do
    at = DateTime.add(DateTime.utc_now(:second), 1, :day)

    assert {:ok, %Oban.Job{conflict?: false}} = AccountDeletionWorker.schedule(42, at)
    assert {:ok, %Oban.Job{conflict?: true}} = AccountDeletionWorker.schedule(42, at)
  end

  test "the daily sweep queues the overdue accounts" do
    at = DateTime.add(DateTime.utc_now(:second), -1, :day)
    user = insert(:user, deletion_requested_at: at, deletion_scheduled_at: at)

    assert perform_job(AccountDeletionSweepWorker, %{}) == :ok
    assert_enqueued(worker: AccountDeletionWorker, args: %{"user_id" => user.id})
  end
end
