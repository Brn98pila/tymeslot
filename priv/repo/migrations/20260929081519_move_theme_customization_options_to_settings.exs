defmodule Tymeslot.Repo.Migrations.MoveThemeCustomizationOptionsToSettings do
  @moduledoc """
  A theme customisation's options move from one column each into a single
  `settings` map, whose keys are whatever the theme's customisation spec
  declares, so a theme with a different option set needs no migration of its
  own.

  Every row's `color_scheme`, `custom_palette_seed` and `background_*` columns
  are copied into `settings`, leaving out the null ones, and the columns and
  their two indexes are then dropped. Only rows whose `settings` is still null
  are filled, and every step is conditional, so the migration is safe to run
  again.

  `down/0` restores the columns and indexes and refills the columns from
  `settings`, so a rollback keeps every option saved since the upgrade.
  """
  use Ecto.Migration

  # Moving the options is the whole of this migration: the schema reads only
  # `settings`, so a row left unfilled would load with no customisation at
  # all, and the columns it empties have no reader left. The defaults in
  # `down/0` are the columns' original constant ones, which PostgreSQL adds
  # without rewriting the table.
  # excellent_migrations:safety-assured-for-this-file raw_sql_executed
  # excellent_migrations:safety-assured-for-this-file operation_update
  # excellent_migrations:safety-assured-for-this-file column_removed
  # excellent_migrations:safety-assured-for-this-file index_not_concurrently
  # excellent_migrations:safety-assured-for-this-file column_added_with_default

  @option_columns ~w(color_scheme custom_palette_seed background_type background_value
                     background_image_path background_video_path)

  def up do
    alter table(:theme_customizations) do
      add_if_not_exists :settings, :map
    end

    if columns_present?() do
      execute("""
      UPDATE theme_customizations
      SET settings = jsonb_strip_nulls(
        jsonb_build_object(
          'color_scheme', color_scheme,
          'custom_palette_seed', custom_palette_seed,
          'background_type', background_type,
          'background_value', background_value,
          'background_image_path', background_image_path,
          'background_video_path', background_video_path
        )
      )
      WHERE settings IS NULL
      """)
    end

    drop_if_exists index(:theme_customizations, [:color_scheme])
    drop_if_exists index(:theme_customizations, [:background_type])

    alter table(:theme_customizations) do
      remove_if_exists :color_scheme, :string
      remove_if_exists :custom_palette_seed, :string
      remove_if_exists :background_type, :string
      remove_if_exists :background_value, :text
      remove_if_exists :background_image_path, :string
      remove_if_exists :background_video_path, :string
    end
  end

  def down do
    alter table(:theme_customizations) do
      add_if_not_exists :color_scheme, :string, null: false, default: "default"
      add_if_not_exists :custom_palette_seed, :string
      add_if_not_exists :background_type, :string, null: false, default: "gradient"
      add_if_not_exists :background_value, :text
      add_if_not_exists :background_image_path, :string
      add_if_not_exists :background_video_path, :string
    end

    execute("""
    UPDATE theme_customizations
    SET color_scheme = COALESCE(settings ->> 'color_scheme', 'default'),
        custom_palette_seed = settings ->> 'custom_palette_seed',
        background_type = COALESCE(settings ->> 'background_type', 'gradient'),
        background_value = settings ->> 'background_value',
        background_image_path = settings ->> 'background_image_path',
        background_video_path = settings ->> 'background_video_path'
    WHERE settings IS NOT NULL
    """)

    create_if_not_exists index(:theme_customizations, [:color_scheme])
    create_if_not_exists index(:theme_customizations, [:background_type])

    alter table(:theme_customizations) do
      remove_if_exists :settings, :map
    end
  end

  # A rerun after the columns are gone has nothing to copy, and the UPDATE
  # naming them would fail.
  defp columns_present? do
    flush()

    %{rows: [[count]]} =
      repo().query!(
        """
        SELECT count(*) FROM information_schema.columns
        WHERE table_schema = current_schema()
          AND table_name = 'theme_customizations'
          AND column_name = ANY($1)
        """,
        [@option_columns]
      )

    count == length(@option_columns)
  end
end
