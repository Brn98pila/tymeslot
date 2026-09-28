defmodule Tymeslot.ThemeCustomizationsEdgeCasesTest do
  use Tymeslot.DataCase, async: true
  @moduletag :themes

  alias Tymeslot.Profiles
  alias Tymeslot.Repo
  alias Tymeslot.ThemeCustomizations
  alias Tymeslot.ThemeCustomizations.Backgrounds

  # ---- Color validation consistency ----

  describe "background colour validation" do
    test "apply_background_change rejects rgb() color values" do
      user = insert(:user)
      {:ok, profile} = Profiles.get_or_create_profile(user.id)

      result =
        ThemeCustomizations.apply_background_change(
          profile.id,
          "1",
          build_customization(profile.id),
          "color",
          "rgb(255,0,0)"
        )

      assert {:error, _reason} = result
    end

    test "apply_background_change rejects named colors" do
      user = insert(:user)
      {:ok, profile} = Profiles.get_or_create_profile(user.id)

      result =
        ThemeCustomizations.apply_background_change(
          profile.id,
          "1",
          build_customization(profile.id),
          "color",
          "transparent"
        )

      assert {:error, _reason} = result
    end

    test "apply_background_change saves a 3-digit hex as lower-case #rrggbb" do
      user = insert(:user)
      {:ok, profile} = Profiles.get_or_create_profile(user.id)

      assert {:ok, customization} =
               ThemeCustomizations.apply_background_change(
                 profile.id,
                 "1",
                 build_customization(profile.id),
                 "color",
                 "#FFF"
               )

      assert customization.background_value == "#ffffff"

      assert ThemeCustomizations.get_by_profile_and_theme(profile.id, "1").background_value ==
               "#ffffff"
    end

    test "apply_background_change rejects the #RRGGBBAA alpha form" do
      user = insert(:user)
      {:ok, profile} = Profiles.get_or_create_profile(user.id)

      assert {:error, _reason} =
               ThemeCustomizations.apply_background_change(
                 profile.id,
                 "1",
                 build_customization(profile.id),
                 "color",
                 "#ff550080"
               )
    end

    test "apply_background_change accepts valid #RRGGBB color" do
      user = insert(:user)
      {:ok, profile} = Profiles.get_or_create_profile(user.id)

      result =
        ThemeCustomizations.apply_background_change(
          profile.id,
          "1",
          build_customization(profile.id),
          "color",
          "#FF5500"
        )

      assert {:ok, customization} = result
      assert customization.background_value == "#ff5500"
    end
  end

  # ---- Unknown theme on the write path ----

  describe "unknown theme" do
    test "apply_background_change rejects operation for unknown theme_id" do
      user = insert(:user)
      {:ok, profile} = Profiles.get_or_create_profile(user.id)
      customization = build_customization(profile.id)

      result =
        ThemeCustomizations.apply_background_change(
          profile.id,
          "999",
          customization,
          "gradient",
          "gradient_1"
        )

      assert {:error, _reason} = result
    end

    test "apply_color_scheme_change rejects operation for unknown theme_id" do
      user = insert(:user)
      {:ok, profile} = Profiles.get_or_create_profile(user.id)
      customization = build_customization(profile.id)

      result =
        ThemeCustomizations.apply_color_scheme_change(profile.id, "999", customization, "purple")

      assert {:error, _reason} = result
    end
  end

  # ---- File cleanup when switching background type ----

  describe "update_theme_customization/2 file cleanup" do
    test "cleans up old image path when switching to gradient (new path is nil)" do
      user = insert(:user)
      {:ok, profile} = Profiles.get_or_create_profile(user.id)

      {:ok, customization} =
        ThemeCustomizations.create_theme_customization(profile.id, "1", %{
          "color_scheme" => "default",
          "background_type" => "image",
          "background_value" => "custom",
          "background_image_path" => "themes/#{profile.id}/1/images/old.jpg"
        })

      # Switch to gradient — new image path is nil
      {:ok, updated} =
        ThemeCustomizations.update_theme_customization(customization, %{
          "background_type" => "gradient",
          "background_value" => "gradient_1",
          "background_image_path" => nil
        })

      assert updated.background_image_path == nil
      assert updated.background_type == "gradient"
    end

    test "cleans up old video path when switching to gradient (new path is nil)" do
      user = insert(:user)
      {:ok, profile} = Profiles.get_or_create_profile(user.id)

      {:ok, customization} =
        ThemeCustomizations.create_theme_customization(profile.id, "2", %{
          "color_scheme" => "default",
          "background_type" => "video",
          "background_value" => "custom",
          "background_video_path" => "themes/#{profile.id}/2/videos/old.mp4"
        })

      {:ok, updated} =
        ThemeCustomizations.update_theme_customization(customization, %{
          "background_type" => "gradient",
          "background_value" => "gradient_1",
          "background_video_path" => nil
        })

      assert updated.background_video_path == nil
      assert updated.background_type == "gradient"
    end
  end

  # ---- clear_conflicting_backgrounds cross-type paths ----

  describe "Backgrounds.clear_conflicting_backgrounds/2 cross-type path behavior" do
    test "switching to image preset does NOT clear video path (paths are independent)" do
      customization = %{
        background_type: "video",
        background_value: "custom",
        background_image_path: nil,
        background_video_path: "themes/1/1/videos/my.mp4"
      }

      result =
        Backgrounds.clear_conflicting_backgrounds(
          %{customization | background_type: "image", background_value: "preset:some-image"},
          "image"
        )

      # Preset image selection clears image path but NOT video path
      assert result.background_image_path == nil
      assert result.background_video_path == "themes/1/1/videos/my.mp4"
    end

    test "switching to gradient clears both image and video paths" do
      customization = %{
        background_type: "image",
        background_value: "custom",
        background_image_path: "themes/1/1/images/my.jpg",
        background_video_path: "themes/1/1/videos/my.mp4"
      }

      result =
        Backgrounds.clear_conflicting_backgrounds(
          %{customization | background_type: "gradient", background_value: "gradient_1"},
          "gradient"
        )

      assert result.background_image_path == nil
      assert result.background_video_path == nil
    end

    test "switching to color clears both image and video paths" do
      customization = %{
        background_type: "video",
        background_value: "custom",
        background_image_path: "themes/1/1/images/my.jpg",
        background_video_path: "themes/1/1/videos/my.mp4"
      }

      result =
        Backgrounds.clear_conflicting_backgrounds(
          %{customization | background_type: "color", background_value: "#FF0000"},
          "color"
        )

      assert result.background_image_path == nil
      assert result.background_video_path == nil
    end
  end

  # ---- upsert race condition retry ----

  describe "create_theme_customization/3 unique constraint retry" do
    test "falls through to update when customization already exists (simulating race)" do
      user = insert(:user)
      {:ok, profile} = Profiles.get_or_create_profile(user.id)

      # Pre-create the customization to simulate a race condition
      {:ok, _existing} =
        ThemeCustomizations.create_theme_customization(profile.id, "1", %{
          "color_scheme" => "default",
          "background_type" => "gradient",
          "background_value" => "gradient_1"
        })

      # Now call upsert — should not error, should update the existing record
      result =
        ThemeCustomizations.upsert_theme_customization(profile.id, "1", %{
          "color_scheme" => "purple"
        })

      assert {:ok, customization} = result
      assert customization.color_scheme == "purple"
    end

    test "upsert is idempotent when called multiple times" do
      user = insert(:user)
      {:ok, profile} = Profiles.get_or_create_profile(user.id)

      attrs = %{
        "color_scheme" => "turquoise",
        "background_type" => "gradient",
        "background_value" => "gradient_1"
      }

      {:ok, first} = ThemeCustomizations.upsert_theme_customization(profile.id, "1", attrs)
      {:ok, second} = ThemeCustomizations.upsert_theme_customization(profile.id, "1", attrs)

      assert first.id == second.id
    end
  end

  # ---- Cascade delete ----

  describe "cascade delete when profile is deleted" do
    test "customizations are removed from DB when profile is deleted" do
      user = insert(:user)
      {:ok, profile} = Profiles.get_or_create_profile(user.id)

      {:ok, customization} =
        ThemeCustomizations.create_theme_customization(profile.id, "1", %{
          "color_scheme" => "default",
          "background_type" => "gradient",
          "background_value" => "gradient_1"
        })

      # The customization exists before deletion
      assert ThemeCustomizations.get_by_profile_and_theme(profile.id, "1").id == customization.id

      # Delete the profile — cascade should remove customizations
      Repo.delete!(profile)

      # Customization must no longer exist
      assert ThemeCustomizations.get_by_profile_and_theme(profile.id, "1") == nil
    end
  end

  # Private helper

  defp build_customization(profile_id) do
    %Tymeslot.ThemeCustomizations.ThemeCustomizationSchema{
      profile_id: profile_id,
      theme_id: "1",
      color_scheme: "default",
      background_type: "gradient",
      background_value: "gradient_1",
      background_image_path: nil,
      background_video_path: nil
    }
  end
end
