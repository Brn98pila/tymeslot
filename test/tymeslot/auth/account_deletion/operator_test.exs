defmodule Tymeslot.Auth.AccountDeletion.OperatorTest do
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :auth

  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Auth
  alias Tymeslot.Auth.UserSessionQueries
  alias Tymeslot.Repo
  alias Tymeslot.Security.Token
  alias Tymeslot.Workers.AccountDeletionWorker

  setup do
    with_config(:tymeslot, enable_admin_ui: true, account_deletion_hook: nil)
    :ok
  end

  test "an admin deletes another account now" do
    admin = insert(:user, is_admin: true)
    target = insert(:user)
    target_id = target.id

    assert {:ok, pending} = Auth.delete_account_now(admin, target.id)

    assert DateTime.diff(DateTime.utc_now(), pending.deletion_scheduled_at) in 0..5
    assert [%{args: %{"user_id" => ^target_id}}] = all_enqueued(worker: AccountDeletionWorker)
  end

  test "replaces a self-service schedule with an immediate one" do
    admin = insert(:user, is_admin: true)
    later = DateTime.add(DateTime.utc_now(:second), 14, :day)

    target =
      insert(:user,
        deletion_requested_at: DateTime.utc_now(:second),
        deletion_scheduled_at: later
      )

    {:ok, _job} = AccountDeletionWorker.schedule(target.id, later)

    assert {:ok, pending} = Auth.delete_account_now(admin, target.id)

    assert DateTime.compare(pending.deletion_scheduled_at, later) == :lt
    assert [job] = all_enqueued(worker: AccountDeletionWorker)
    assert DateTime.compare(job.scheduled_at, later) == :lt
  end

  test "ends the target's sessions and leaves other users' alone" do
    admin = insert(:user, is_admin: true)
    target = insert(:user)
    bystander = insert(:user)
    insert(:user_session, user: target, token_hash: Token.hash_token("target-token"))
    insert(:user_session, user: bystander, token_hash: Token.hash_token("bystander-token"))

    assert {:ok, _pending} = Auth.delete_account_now(admin, target.id)

    refute UserSessionQueries.get_user_by_session_token("target-token")
    assert UserSessionQueries.get_user_by_session_token("bystander-token")
  end

  test "an admin demoted since their struct was loaded is forbidden" do
    stale_admin = insert(:user, is_admin: true)
    insert(:user, is_admin: true)
    target = insert(:user)

    stale_admin |> Ecto.Changeset.change(is_admin: false) |> Repo.update!()

    assert Auth.delete_account_now(stale_admin, target.id) == {:error, :forbidden}
    refute Repo.get!(Tymeslot.Auth.UserSchema, target.id).deletion_scheduled_at
  end

  test "an admin cannot delete themselves" do
    admin = insert(:user, is_admin: true)
    insert(:user, is_admin: true)

    assert Auth.delete_account_now(admin, admin.id) == {:error, :self}
  end

  test "a non-admin cannot delete anyone" do
    assert Auth.delete_account_now(insert(:user), insert(:user).id) == {:error, :forbidden}
  end

  test "the admin UI switch gates admin actors but not the release shell" do
    with_config(:tymeslot, :enable_admin_ui, false)
    admin = insert(:user, is_admin: true)
    target = insert(:user)

    assert Auth.delete_account_now(admin, target.id) == {:error, :admin_ui_disabled}
    assert {:ok, _pending} = Auth.delete_account_now(:cli, target.id)
  end

  test "the release shell needs force to delete the last admin" do
    only_admin = insert(:user, is_admin: true)

    assert Auth.delete_account_now(:cli, only_admin.id) == {:error, :last_admin}
    assert {:ok, _pending} = Auth.delete_account_now(:cli, only_admin.id, force: true)
  end
end
