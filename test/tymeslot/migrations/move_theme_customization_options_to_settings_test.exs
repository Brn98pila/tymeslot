defmodule Tymeslot.Migrations.MoveThemeCustomizationOptionsToSettingsTest do
  @moduledoc """
  Value-correctness regression for
  `20260929081519_move_theme_customization_options_to_settings`, which copies
  each theme customisation's option columns into the `settings` map the
  schema now reads, then drops the columns.

  The decisive property is that **no stored option is lost** in either
  direction: the schema reads only `settings`, so a row left unfilled would
  load with no customisation at all, and the previous release reads only the
  columns, so `down/0` must carry any write made since the upgrade back into
  them.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :database
  @moduletag :migrations
  @moduletag :themes

  alias Tymeslot.Repo
  alias Tymeslot.Test.MigrationRunner

  @version 20_260_929_081_519

  defp insert_legacy_row(profile_id, theme_id, columns) do
    {names, values} = Enum.unzip(columns)
    names = Enum.map_join(names, ", ", &Atom.to_string/1)
    params = Enum.map_join(1..length(values), ", ", &"$#{&1 + 2}")

    Repo.query!(
      """
      INSERT INTO theme_customizations (profile_id, theme_id, #{names}, inserted_at, updated_at)
      VALUES ($1, $2, #{params}, now(), now())
      """,
      [profile_id, theme_id | values]
    )
  end

  defp settings(profile_id, theme_id) do
    %{rows: [[settings]]} =
      Repo.query!(
        "SELECT settings FROM theme_customizations WHERE profile_id = $1 AND theme_id = $2",
        [profile_id, theme_id]
      )

    settings
  end

  defp columns(profile_id, theme_id) do
    %{rows: [row], columns: names} =
      Repo.query!(
        """
        SELECT color_scheme, custom_palette_seed, background_type, background_value,
               background_image_path, background_video_path
        FROM theme_customizations WHERE profile_id = $1 AND theme_id = $2
        """,
        [profile_id, theme_id]
      )

    names |> Enum.zip(row) |> Map.new()
  end

  defp option_columns do
    %{rows: rows} =
      Repo.query!("""
      SELECT column_name FROM information_schema.columns
      WHERE table_schema = current_schema() AND table_name = 'theme_customizations'
        AND column_name IN ('color_scheme', 'custom_palette_seed', 'background_type',
                            'background_value', 'background_image_path', 'background_video_path')
      """)

    List.flatten(rows)
  end

  test "every option column is copied into settings, leaving out the null ones" do
    profile = insert(:profile)
    MigrationRunner.down!(@version)

    insert_legacy_row(profile.id, "1",
      color_scheme: "sunset",
      custom_palette_seed: "#112233",
      background_type: "image",
      background_value: "custom",
      background_image_path: "1/1/backgrounds/photo.webp"
    )

    insert_legacy_row(profile.id, "2", background_value: nil)

    MigrationRunner.up!(@version)

    assert settings(profile.id, "1") == %{
             "color_scheme" => "sunset",
             "custom_palette_seed" => "#112233",
             "background_type" => "image",
             "background_value" => "custom",
             "background_image_path" => "1/1/backgrounds/photo.webp"
           }

    # The columns' own defaults are copied like any other value.
    assert settings(profile.id, "2") == %{
             "color_scheme" => "default",
             "background_type" => "gradient"
           }

    assert option_columns() == []
  end

  test "a rollback carries writes made since the upgrade back into the columns" do
    customization =
      insert(:theme_customization,
        theme_id: "2",
        color_scheme: "ocean",
        background_type: "video",
        background_value: "custom",
        background_video_path: "1/2/backgrounds/clip.mp4"
      )

    MigrationRunner.down!(@version)

    assert columns(customization.profile_id, "2") == %{
             "color_scheme" => "ocean",
             "custom_palette_seed" => nil,
             "background_type" => "video",
             "background_value" => "custom",
             "background_image_path" => nil,
             "background_video_path" => "1/2/backgrounds/clip.mp4"
           }

    MigrationRunner.up!(@version)

    assert settings(customization.profile_id, "2") == customization.settings
  end

  test "running it again leaves settings written since the first run alone" do
    customization = insert(:theme_customization, theme_id: "1", color_scheme: "forest")

    MigrationRunner.replay!(@version)

    assert settings(customization.profile_id, "1")["color_scheme"] == "forest"
    assert option_columns() == []
  end
end
