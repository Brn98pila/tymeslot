defmodule Tymeslot.Auth.AccountDeletion.Operator do
  @moduledoc """
  Deleting someone else's account now, bypassing the grace period: from the
  admin users tab (an admin actor) or a release shell (`:cli`).

  Same guarantees as `Tymeslot.Auth.AdminRoles`: the actor's admin flag is
  re-read inside the transaction, so a stale struct does not count, and the
  admins are locked, so two concurrent deletions cannot remove the last
  admin between them. An admin can delete neither themselves (their own
  account settings do that, with re-authentication) nor the last admin;
  `:cli` may delete the last admin only with `force: true`, as with
  `Tymeslot.Release.demote_admin/2`. The admin UI switch gates admin actors
  only, so operators of an install without the admin UI can still use the
  release shell.

  The account is marked pending with `scheduled_at` now, replacing any
  self-service schedule and its waiting job, every session ends, and the
  deletion job is queued to run at once. No notice is emailed: the operator
  owns that conversation.
  """

  require Logger

  alias Tymeslot.Auth.{AdminRoles, AdminUserQueries, Session, UserQueries, UserSchema}
  alias Tymeslot.Jobs
  alias Tymeslot.Repo
  alias Tymeslot.Workers.AccountDeletionWorker

  @type actor :: UserSchema.t() | :cli
  @type error :: :admin_ui_disabled | :forbidden | :not_found | :self | :last_admin | term()

  @spec delete_now(actor(), pos_integer(), keyword()) ::
          {:ok, UserSchema.t()} | {:error, error()}
  def delete_now(actor, target_user_id, opts \\ []) do
    with :ok <- ensure_admin_ui(actor),
         {:ok, {pending, session_hashes}} <-
           schedule_now(actor, target_user_id, Keyword.get(opts, :force, false)) do
      Session.disconnect_sessions(session_hashes)

      Logger.info("Account deletion started by an operator",
        event: "operator_account_deletion",
        target_user_id: pending.id,
        actor: actor_label(actor)
      )

      {:ok, pending}
    end
  end

  defp schedule_now(actor, target_user_id, force?) do
    now = DateTime.utc_now(:second)

    Repo.transaction(fn ->
      AdminUserQueries.lock_admins()

      with :ok <- authorise(actor),
           {:ok, target} <- UserQueries.get_user_for_update(target_user_id),
           :ok <- refuse_self(actor, target),
           :ok <- refuse_last_admin(target, force?),
           {:ok, pending} <-
             UserQueries.mark_deletion_scheduled(target, target.deletion_requested_at || now, now),
           {_count, nil} <- Jobs.delete_user_jobs(AccountDeletionWorker, target.id),
           {:ok, _job} <- AccountDeletionWorker.schedule(target.id, now) do
        {pending, Session.delete_session_rows(pending.id)}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp ensure_admin_ui(:cli), do: :ok

  defp ensure_admin_ui(_admin) do
    if AdminRoles.admin_ui_enabled?(), do: :ok, else: {:error, :admin_ui_disabled}
  end

  defp authorise(:cli), do: :ok

  defp authorise(%UserSchema{is_admin: true, id: actor_id}) do
    case UserQueries.get_user(actor_id) do
      {:ok, %UserSchema{is_admin: true}} -> :ok
      _demoted_or_deleted -> {:error, :forbidden}
    end
  end

  defp authorise(_actor), do: {:error, :forbidden}

  defp refuse_self(%UserSchema{id: id}, %UserSchema{id: id}), do: {:error, :self}
  defp refuse_self(_actor, _target), do: :ok

  defp refuse_last_admin(%UserSchema{is_admin: true}, false) do
    if AdminUserQueries.count_admins() <= 1, do: {:error, :last_admin}, else: :ok
  end

  defp refuse_last_admin(_target, _force?), do: :ok

  defp actor_label(:cli), do: "cli"
  defp actor_label(%UserSchema{id: id}), do: id
end
