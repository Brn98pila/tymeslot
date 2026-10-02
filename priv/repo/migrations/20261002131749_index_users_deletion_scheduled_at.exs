defmodule Tymeslot.Repo.Migrations.IndexUsersDeletionScheduledAt do
  @moduledoc """
  Partial index behind the daily sweep for overdue deletions
  (`UserQueries.list_due_deletion_ids/2`) and the pending-host checks on
  public pages. Only accounts pending deletion carry a value, so the index
  stays tiny. Built concurrently so the `users` table is never locked.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    create_if_not_exists(
      index(:users, [:deletion_scheduled_at],
        where: "deletion_scheduled_at IS NOT NULL",
        concurrently: true,
        name: :users_deletion_scheduled_at_index
      )
    )
  end

  def down do
    drop_if_exists(
      index(:users, [:deletion_scheduled_at],
        name: :users_deletion_scheduled_at_index,
        concurrently: true
      )
    )
  end
end
