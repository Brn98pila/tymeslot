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
      assert customization.color_scheme == "purple"
      assert customization.background_type == "gradient"
      assert customization.background_value == "gradient_1"
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
      assert customization.color_scheme == "ocean"
      assert customization.background_type == "color"
      assert customization.background_value == "#082f49"
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

      assert updated.color_scheme == "sunset"
      assert updated.background_value == "gradient_3"
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

      assert created.color_scheme == "purple"
      assert created.background_type == "video"
      assert created.background_value == "preset:rhythm-default"
    end

    test "upsert_theme_customization/3 creates a Quill customisation with the Aurora gradient",
         %{profile: profile} do
      {:ok, created} =
        ThemeCustomizations.upsert_theme_customization(profile.id, "1", %{
          "color_scheme" => "purple"
        })

      assert {created.background_type, created.background_value} == {"gradient", "gradient_1"}
    end

    test "default_customization/2 builds an unsaved customisation from the theme's spec" do
      assert %ThemeCustomizationSchema{
               id: nil,
               profile_id: 7,
               theme_id: "2",
               color_scheme: "default",
               background_type: "video",
               background_value: "preset:rhythm-default"
             } = ThemeCustomizations.default_customization(7, "2")
    end
  end
end
