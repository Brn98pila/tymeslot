defmodule Tymeslot.ThemeCustomizations.ConcurrentSavesRaceTest do
  @moduledoc """
  Two saves of one theme customisation close together, on real connections
  staged by `Tymeslot.Test.RaceConductor` (see its moduledoc for why the
  module is synchronous and why `on_exit` deletes what it committed).

  Each contender parks right after its first read of the row. A save locks
  the row as it reads it, so the second one waits for the first to commit
  and then applies its change to what the first stored. Without the lock
  both read the same row and the later write puts the old settings back:
  the other tab's change is lost, and an upload the first save stored is
  left on disk with nothing naming it.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :themes
  @moduletag :integration

  import Ecto.Query, only: [from: 2]
  import Tymeslot.Test.RaceConductor, only: [race: 1, unboxed: 1]

  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.Media.Uploads
  alias Tymeslot.Profiles.ProfileSchema
  alias Tymeslot.Repo
  alias Tymeslot.Test.MediaFixtures
  alias Tymeslot.Test.RaceConductor
  alias Tymeslot.ThemeCustomizations
  alias Tymeslot.ThemeCustomizations.ThemeCustomizationSchema

  @theme_id "1"

  setup do
    upload_root =
      Path.join(System.tmp_dir!(), "tymeslot_race_#{System.unique_integer([:positive])}")

    original_root = Application.get_env(:tymeslot, :upload_directory)
    Application.put_env(:tymeslot, :upload_directory, upload_root)

    profile =
      unboxed(fn ->
        user = insert(:user)
        insert(:profile, user: user)
      end)

    on_exit(fn ->
      unboxed(fn ->
        Repo.delete_all(from(c in ThemeCustomizationSchema, where: c.profile_id == ^profile.id))

        Repo.delete_all(from(p in ProfileSchema, where: p.id == ^profile.id))
        Repo.delete_all(from(u in UserSchema, where: u.id == ^profile.user_id))
      end)

      Application.put_env(:tymeslot, :upload_directory, original_root)
      File.rm_rf(upload_root)
    end)

    RaceConductor.attach_parking()

    %{profile: profile}
  end

  describe "an upload in one tab and an option change in another" do
    setup %{profile: profile} do
      unboxed(fn ->
        {:ok, _row} = ThemeCustomizations.upsert_theme_customization(profile.id, @theme_id, %{})
      end)

      :ok
    end

    test "both changes are kept and the uploaded image stays on disk", %{profile: profile} do
      [uploaded, changed] =
        race([
          fn hold ->
            RaceConductor.arm(hold, &read_of_customizations?/1)
            upload_image(profile)
          end,
          fn hold ->
            RaceConductor.arm(hold, &read_of_customizations?/1)

            ThemeCustomizations.apply_option(profile.id, @theme_id, :palette, %{
              "field" => "scheme",
              "value" => "purple"
            })
          end
        ])

      assert {:ok, _row} = uploaded
      assert {:ok, _row} = changed

      settings = stored_settings(profile)
      assert settings["color_scheme"] == "purple"
      assert settings["background_type"] == "image"
      assert settings["background_image_path"] =~ ~r{^themes/#{profile.id}/1/images/}
      assert stored_files(profile) == [absolute(settings["background_image_path"])]
    end
  end

  describe "two background image uploads" do
    setup %{profile: profile} do
      original =
        unboxed(fn ->
          {:ok, row} = upload_image(profile)
          row.settings["background_image_path"]
        end)

      %{original: original}
    end

    test "the later one wins and no file is left that the row does not name", %{
      profile: profile,
      original: original
    } do
      results =
        race(
          for _tab <- 1..2 do
            fn hold ->
              RaceConductor.arm(hold, &read_of_customizations?/1)
              upload_image(profile)
            end
          end
        )

      assert [{:ok, _first}, {:ok, _second}] = results

      path = stored_settings(profile)["background_image_path"]
      assert path not in [nil, original]
      assert stored_files(profile) == [absolute(path)]
    end
  end

  describe "the first two saves of a theme" do
    test "both create or update the one row, keeping each change", %{profile: profile} do
      results =
        race(
          for {option, field, value} <- [
                {:palette, "scheme", "ocean"},
                {:background, "color", "#123456"}
              ] do
            fn hold ->
              RaceConductor.arm(hold, &read_of_customizations?/1)

              ThemeCustomizations.apply_option(profile.id, @theme_id, option, %{
                "field" => field,
                "value" => value
              })
            end
          end
        )

      assert [{:ok, _first}, {:ok, _second}] = results

      assert %{
               "color_scheme" => "ocean",
               "background_type" => "color",
               "background_value" => "#123456"
             } = stored_settings(profile)
    end
  end

  defp upload_image(profile) do
    path = Path.join(System.tmp_dir!(), "#{System.unique_integer([:positive])}-bg.png")
    File.write!(path, MediaFixtures.png())

    try do
      ThemeCustomizations.attach_asset(profile.id, @theme_id, :background_image_path, %{
        path: path,
        filename: "bg.png"
      })
    after
      File.rm(path)
    end
  end

  defp read_of_customizations?(metadata),
    do:
      metadata[:source] == "theme_customizations" and
        String.starts_with?(metadata[:query], "SELECT")

  defp stored_settings(profile) do
    unboxed(fn ->
      ThemeCustomizations.get_by_profile_and_theme(profile.id, @theme_id).settings
    end)
  end

  defp stored_files(profile) do
    [Uploads.root(), "themes", to_string(profile.id), "**", "*"]
    |> Path.join()
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
  end

  defp absolute(relative), do: Path.join(Uploads.root(), relative)
end
