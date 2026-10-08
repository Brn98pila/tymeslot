defmodule Tymeslot.Release do
  @moduledoc """
  Helpers callable from a packaged release where `mix` is not available.

  Designed to be invoked via `bin/tymeslot rpc` (against a running node) or
  `bin/tymeslot eval` (in a one-shot helper VM). The mix tasks under
  `Mix.Tasks.Tymeslot.*` delegate here so the implementation stays in one
  place and behaves identically across dev (`mix tymeslot.promote_admin`)
  and production (`bin/tymeslot rpc 'Tymeslot.Release.promote_admin("…")'`).
  """

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
    ensure_started()

    with :ok <- ensure_admin_ui_enabled(),
         {:ok, user} <- UserQueries.get_user_by_email(email) do
      AdminRoles.demote(:cli, user.id, force: force?)
    end
  end

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
