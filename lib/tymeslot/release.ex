defmodule Tymeslot.Release do
  @moduledoc """
  Helpers callable from a packaged release where `mix` is not available.

  Designed to be invoked via `bin/tymeslot rpc` (against a running node) or
  `bin/tymeslot eval` (in a one-shot helper VM). The mix tasks under
  `Mix.Tasks.Tymeslot.*` delegate here so the implementation stays in one
  place and behaves identically across dev (`mix tymeslot.promote_admin`)
  and production (`bin/tymeslot rpc 'Tymeslot.Release.promote_admin("…")'`).
  """

  alias Tymeslot.Auth
  alias Tymeslot.Auth.{AdminRoles, AdminUserQueries, UserQueries, UserSchema}
  alias Tymeslot.Media.UploadMetadataSweep

  @doc """
  Promotes the user with the given email to admin.

  Returns:
    * `{:ok, %UserSchema{}}` on success (or if already admin)
    * `{:error, :not_found}` if no user has that email
    * `{:error, :admin_ui_disabled}` if the admin UI is disabled (SaaS)
    * `{:error, changeset}` if the update itself fails
  """
  @spec promote_admin(String.t()) ::
          {:ok, UserSchema.t()}
          | {:error, :not_found | :admin_ui_disabled | Ecto.Changeset.t()}
  def promote_admin(email) when is_binary(email) do
    ensure_started()

    with {:ok, user} <- UserQueries.get_user_by_email(email) do
      AdminRoles.promote(:cli, user.id)
    end
  end

  @doc """
  Demotes the user with the given email from admin.

  Refuses to demote an admin when no other admin could still sign in
  (the guard is `AdminRoles.remaining_signin_capable_admins?/1`) unless
  `force?` is true. This mirrors the
  pre-check `mix tymeslot.demote_admin` applies before reaching
  this function, so the documented production path
  (`bin/tymeslot rpc 'Tymeslot.Release.demote_admin("…")'`) gets the same
  protection rather than relying solely on the dev-only Mix task. Below this
  guard, the `:cli` actor still skips `AdminRoles.demote/2`'s own last-admin
  check by design — that remains the operator escape hatch for recovering an
  already-stranded install; `force?` is this function's equivalent for
  callers going through it directly.
  """
  @spec demote_admin(String.t(), boolean()) ::
          {:ok, UserSchema.t()}
          | {:error, :not_found | :admin_ui_disabled | :last_admin | Ecto.Changeset.t()}
  def demote_admin(email, force? \\ false) when is_binary(email) do
    ensure_started()

    with :ok <- ensure_admin_ui_enabled(),
         {:ok, user} <- UserQueries.get_user_by_email(email),
         :ok <- check_last_admin(user, force?) do
      AdminRoles.demote(:cli, user.id)
    end
  end

  @doc """
  Deletes the account with the given email now, bypassing any grace period,
  and waits for the deletion to finish:

      bin/tymeslot rpc 'Tymeslot.Release.delete_account("someone@example.com")'

  Refuses the only remaining admin unless `force?` is true. Returns
  `{:ok, :deleted}`, or the error that stopped the deletion; in that case the
  queued deletion job retries by itself.
  """
  @spec delete_account(String.t(), boolean()) :: {:ok, :deleted} | {:error, term()}
  def delete_account(email, force? \\ false) when is_binary(email) do
    ensure_started()

    with {:ok, user} <- UserQueries.get_user_by_email(email),
         {:ok, _pending} <-
           Auth.delete_account_now(:cli, user.id, force: force?, job_at: fallback_job_at()) do
      case Auth.run_scheduled_deletion(user.id) do
        {:ok, outcome} when outcome in [:deleted, :already_deleted] -> {:ok, :deleted}
        {:ok, outcome} -> {:error, outcome}
        {:snooze, _seconds} -> {:error, :not_due}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # The deletion runs synchronously, so the queued job is only the retry if
  # that fails. Queued for now, Oban would race the synchronous run and do
  # the cleanup and the hook twice; on success it finds the account gone.
  defp fallback_job_at, do: DateTime.add(DateTime.utc_now(:second), 5, :minute)

  # Checked here too (rather than relying solely on `AdminRoles.demote/2`'s
  # own check) so it runs before the last-admin guard below, keeping the
  # error precedence promote_admin/1 and the pre-fix demote_admin/1 already
  # had: a disabled admin UI is reported as such even for a sole admin.
  defp ensure_admin_ui_enabled do
    if AdminRoles.admin_ui_enabled?(), do: :ok, else: {:error, :admin_ui_disabled}
  end

  # `force?` is the only thing this adds over the shared rule: the `:cli`
  # actor skips `AdminRoles`' own guard, so without this pre-check the
  # documented production path would have no guard at all.
  defp check_last_admin(%UserSchema{is_admin: true} = user, false) do
    if AdminRoles.remaining_signin_capable_admins?(user), do: :ok, else: {:error, :last_admin}
  end

  defp check_last_admin(_user, _force?), do: :ok

  @doc """
  Lists every admin user (email + id). Useful for operators verifying the
  current state of an install.
  """
  @spec list_admins() :: [%{id: integer(), email: String.t()}]
  def list_admins do
    ensure_started()

    Enum.map(AdminUserQueries.list_admins(), fn user -> %{id: user.id, email: user.email} end)
  end

  @doc """
  Strips location, capture time and device metadata from every image and
  video already in the upload directory. See `Tymeslot.Media.UploadMetadataSweep`.

  The sweep runs once by itself after the upgrade that introduced it; this is
  for running it again, for instance after restoring an old uploads backup.

  Touches only files, never the database, so it needs no running node:

      bin/tymeslot eval 'Tymeslot.Release.strip_upload_metadata()'

  Run it as the user the app runs as, so rewritten files keep their owner.
  """
  @spec strip_upload_metadata() :: UploadMetadataSweep.report()
  def strip_upload_metadata, do: UploadMetadataSweep.run()

  # When called via `bin/tymeslot eval`, the application isn't started — we
  # need at least the Repo running to issue queries. `rpc` against a live
  # node already has everything up, so the second start is a no-op.
  defp ensure_started do
    {:ok, _apps} = Application.ensure_all_started(:tymeslot)
    :ok
  end
end
