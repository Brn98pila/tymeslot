defmodule Tymeslot.Release do
  @moduledoc """
  Helpers callable from a packaged release where `mix` is not available.

  `migrate/1` and `strip_upload_metadata/0` run in a one-shot helper VM,
  `bin/tymeslot eval`, and need no running node. Every other helper acts
  on the running node and goes through `bin/tymeslot rpc`: under `eval` it
  raises rather than boot a second copy of the application (its Oban
  queues, endpoint and start-up tasks) beside the live one. The mix tasks
  under `Mix.Tasks.Tymeslot.*` delegate here so the implementation stays in
  one place and behaves identically across dev (`mix
  tymeslot.promote_admin`) and production (`bin/tymeslot rpc
  'Tymeslot.Release.promote_admin("…")'`).
  """

  alias Ecto.Migrator
  alias Tymeslot.Auth
  alias Tymeslot.Auth.{AdminRoles, AdminUserQueries, UserQueries, UserSchema}
  alias Tymeslot.Media.UploadMetadataSweep

  @doc """
  Runs every pending migration of `app`'s repos (its `:ecto_repos`), each
  through `Ecto.Migrator.with_repo/2`, which starts only the repo. Every
  start script runs it before the server starts:

      bin/tymeslot eval 'Tymeslot.Release.migrate()'

  `run_opts` go to `Ecto.Migrator.run/4` beside `all: true`.
  """
  @spec migrate(atom(), keyword()) :: :ok
  def migrate(app \\ :tymeslot, run_opts \\ []) do
    :ok = Application.ensure_loaded(app)
    run_opts = Keyword.put(run_opts, :all, true)

    for repo <- Application.fetch_env!(app, :ecto_repos) do
      {:ok, _migrated, _apps} =
        Migrator.with_repo(repo, &Migrator.run(&1, :up, run_opts))
    end

    :ok
  end

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
    ensure_running!()

    with {:ok, user} <- UserQueries.get_user_by_email(email) do
      AdminRoles.promote(:cli, user.id)
    end
  end

  @doc """
  Demotes the user with the given email from admin.

  Refuses to demote an admin when no other admin could still sign in, unless
  `force?` is true. The check is `AdminRoles.demote/3`'s own last-admin guard,
  made under the admin row lock, so two operators demoting the last two
  admins at once cannot both succeed. `force?` is the operator escape hatch,
  for instance to remove a compromised sole admin before promoting a
  replacement. `mix tymeslot.demote_admin` and the documented production
  path (`bin/tymeslot rpc 'Tymeslot.Release.demote_admin("…")'`) both come
  through here.
  """
  @spec demote_admin(String.t(), boolean()) ::
          {:ok, UserSchema.t()}
          | {:error, :not_found | :admin_ui_disabled | :last_admin | Ecto.Changeset.t()}
  def demote_admin(email, force? \\ false) when is_binary(email) do
    ensure_running!()

    with :ok <- ensure_admin_ui_enabled(),
         {:ok, user} <- UserQueries.get_user_by_email(email) do
      AdminRoles.demote(:cli, user.id, force: force?)
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
    ensure_running!()

    with {:ok, user} <- UserQueries.get_user_by_email(email),
         {:ok, _pending} <-
           Auth.delete_account_now(:cli, user.id, force: force?, job_at: fallback_job_at()) do
      case Auth.run_scheduled_deletion(user.id, force: force?) do
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

  # Checked here too (rather than relying solely on `AdminRoles.demote/3`'s
  # own check) so a disabled admin UI is reported before an unknown email,
  # the same precedence promote_admin/1 has.
  defp ensure_admin_ui_enabled do
    if AdminRoles.admin_ui_enabled?(), do: :ok, else: {:error, :admin_ui_disabled}
  end

  @doc """
  Lists every admin user (email + id). Useful for operators verifying the
  current state of an install.
  """
  @spec list_admins() :: [%{id: integer(), email: String.t()}]
  def list_admins do
    ensure_running!()

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

  # These helpers act on the running node (its repo, Oban queues and
  # caches). Under `bin/tymeslot eval` nothing is running, and starting the
  # application there would boot a second copy beside the live node, so
  # they refuse instead. `rpc` and the mix tasks (after `app.start`) run
  # where the application is already up.
  @doc false
  # Public only so the refusal can be tested without stopping the application.
  @spec ensure_running!([{atom(), charlist(), charlist()}]) :: :ok
  def ensure_running!(started \\ Application.started_applications()) do
    unless List.keymember?(started, :tymeslot, 0) do
      raise "Tymeslot.Release needs the running node: use `bin/tymeslot rpc`, not `eval`"
    end

    :ok
  end
end
