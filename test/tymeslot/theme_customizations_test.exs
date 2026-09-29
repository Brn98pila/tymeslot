defmodule Tymeslot.ThemeCustomizationsTest do
  use Tymeslot.DataCase, async: true
  @moduletag :utils

  alias Tymeslot.Profiles
  alias Tymeslot.ThemeCustomizations
  alias Tymeslot.ThemeCustomizations.ThemeCustomizationSchema

  describe "theme customizations" do
    setup do
      user = insert(:user)
      {:ok, profile} = Profiles.get_or_create_profile(user.id)
      %{profile: profile}
    end

    test "create_theme_customization/3 creates a customization for a theme", %{profile: profile} do
      attrs = %{
        "color_scheme" => "purple",
        "background_type" => "gradient",
        "background_value" => "gradient_1"
      }

      assert {:ok, customization} =
               ThemeCustomizations.create_theme_customization(profile.id, "1", attrs)

      assert customization.theme_id == "1"
      assert customization.settings["color_scheme"] == "purple"
      assert customization.settings["background_type"] == "gradient"
      assert customization.settings["background_value"] == "gradient_1"
    end

    test "create_theme_customization/3 starts a new row from the theme's defaults", %{
      profile: profile
    } do
      assert {:ok, customization} =
               ThemeCustomizations.create_theme_customization(profile.id, "2", %{
                 "color_scheme" => "ocean"
               })

      assert customization.settings == %{
               "color_scheme" => "ocean",
               "background_type" => "video",
               "background_value" => "preset:rhythm-default"
             }
    end

    test "get_by_profile_and_theme/2 returns the customization", %{profile: profile} do
      attrs = %{
        "color_scheme" => "ocean",
        "background_type" => "color",
        "background_value" => "#082f49"
      }

      {:ok, _result} = ThemeCustomizations.create_theme_customization(profile.id, "2", attrs)

      customization = ThemeCustomizations.get_by_profile_and_theme(profile.id, "2")
      assert customization.theme_id == "2"
      assert customization.settings["color_scheme"] == "ocean"
      assert customization.settings["background_type"] == "color"
      assert customization.settings["background_value"] == "#082f49"
    end

    test "upsert_theme_customization/3 updates existing customization", %{profile: profile} do
      # Create initial customization
      initial_attrs = %{
        "color_scheme" => "default",
        "background_type" => "gradient",
        "background_value" => "gradient_1"
      }

      {:ok, _result} =
        ThemeCustomizations.create_theme_customization(profile.id, "1", initial_attrs)

      # Update it
      update_attrs = %{
        "color_scheme" => "sunset",
        "background_type" => "gradient",
        "background_value" => "gradient_3"
      }

      {:ok, updated} =
        ThemeCustomizations.upsert_theme_customization(profile.id, "1", update_attrs)

      assert updated.settings["color_scheme"] == "sunset"
      assert updated.settings["background_value"] == "gradient_3"
    end

    test "delete_theme_customization/1 removes customization", %{profile: profile} do
      attrs = %{
        "color_scheme" => "forest",
        "background_type" => "gradient",
        "background_value" => "gradient_4"
      }

      {:ok, customization} =
        ThemeCustomizations.create_theme_customization(profile.id, "2", attrs)

      assert {:ok, _result} = ThemeCustomizations.delete_theme_customization(customization)

      # Check customization is deleted
      assert ThemeCustomizations.get_by_profile_and_theme(profile.id, "2") == nil
    end

    test "supports_background?/2 answers from the theme's spec" do
      assert ThemeCustomizations.supports_background?("2", :video)
      refute ThemeCustomizations.supports_background?("9", :video)
    end

    test "every shipped theme offers image and video backgrounds" do
      for theme_id <- ["1", "2"] do
        assert ThemeCustomizations.supports_background?(theme_id, :image), theme_id
        assert ThemeCustomizations.supports_background?(theme_id, :video), theme_id
      end
    end

    test "get_defaults/1 returns theme-specific defaults" do
      assert ThemeCustomizations.get_defaults("1") == %{
               "background_type" => "gradient",
               "background_value" => "gradient_1",
               "color_scheme" => "default"
             }

      assert ThemeCustomizations.get_defaults("2") == %{
               "background_type" => "video",
               "background_value" => "preset:rhythm-default",
               "color_scheme" => "default"
             }
    end

    test "to_map/1 converts customization to map" do
      customization = %ThemeCustomizationSchema{
        theme_id: "1",
        settings: %{
          "color_scheme" => "purple",
          "background_type" => "gradient",
          "background_value" => "gradient_1"
        }
      }

      map = ThemeCustomizations.to_map(customization)

      assert map["color_scheme"] == "purple"
      assert map["background_type"] == "gradient"
    end

    test "to_map/1 handles nil" do
      assert ThemeCustomizations.to_map(nil) == %{}
    end

    test "video_preset_keys/0 lists the shipped video presets in order" do
      keys = ThemeCustomizations.video_preset_keys()

      assert "preset:rhythm-default" in keys
      assert keys == Enum.sort(keys)
    end

    test "upsert_theme_customization/3 creates a Rhythm customisation with Rhythm's own background",
         %{profile: profile} do
      {:ok, created} =
        ThemeCustomizations.upsert_theme_customization(profile.id, "2", %{
          "color_scheme" => "purple"
        })

      assert created.settings["color_scheme"] == "purple"
      assert created.settings["background_type"] == "video"
      assert created.settings["background_value"] == "preset:rhythm-default"
    end

    test "upsert_theme_customization/3 creates a Quill customisation with the Aurora gradient",
         %{profile: profile} do
      {:ok, created} =
        ThemeCustomizations.upsert_theme_customization(profile.id, "1", %{
          "color_scheme" => "purple"
        })

      assert {created.settings["background_type"], created.settings["background_value"]} ==
               {"gradient", "gradient_1"}
    end

    test "default_customization/2 builds an unsaved customisation from the theme's spec" do
      assert %ThemeCustomizationSchema{
               id: nil,
               profile_id: 7,
               theme_id: "2",
               settings: %{
                 "color_scheme" => "default",
                 "background_type" => "video",
                 "background_value" => "preset:rhythm-default"
               }
             } = ThemeCustomizations.default_customization(7, "2")
    end
  end
end
