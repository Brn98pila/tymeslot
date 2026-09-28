defmodule Tymeslot.ThemeCustomizationsBackgroundsTest do
  use Tymeslot.DataCase, async: true
  @moduletag :utils

  alias Tymeslot.ThemeCustomizations.Backgrounds
  alias Tymeslot.ThemeCustomizations.ThemeCustomizationSchema

  describe "Backgrounds module" do
    test "determine_cleanup_files/2 identifies files to cleanup" do
      old = %ThemeCustomizationSchema{
        background_type: "image",
        background_value: "custom",
        background_image_path: "old/image.jpg",
        background_video_path: nil
      }

      new = %ThemeCustomizationSchema{
        background_type: "gradient",
        background_value: "gradient_1",
        background_image_path: nil,
        background_video_path: nil
      }

      cleanup = Backgrounds.determine_cleanup_files(old, new)

      assert length(cleanup) == 1
      assert %{background_image_path: "old/image.jpg"} in cleanup
    end

    test "determine_cleanup_files/2 returns empty when no cleanup needed" do
      old = %ThemeCustomizationSchema{
        background_type: "gradient",
        background_value: "gradient_1",
        background_image_path: nil,
        background_video_path: nil
      }

      new = %ThemeCustomizationSchema{
        background_type: "gradient",
        background_value: "gradient_2",
        background_image_path: nil,
        background_video_path: nil
      }

      assert Backgrounds.determine_cleanup_files(old, new) == []
    end
  end
end
