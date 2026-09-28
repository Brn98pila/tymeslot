defmodule TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomizationBackgroundUploadTest do
  @moduledoc """
  Verifies a successful background image upload in the theme customizer
  pushes "upload-complete" so the `AutoUpload` hook clears the file picker,
  mirroring the avatar upload fixes (dashboard and onboarding).
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :themes
  @moduletag :live

  import Tymeslot.DashboardTestHelpers

  alias Tymeslot.ThemeCustomizations
  alias Tymeslot.ThemeCustomizations.Storage

  # Minimal valid PNG (magic bytes + IHDR) — accepted by allow_upload's accept
  # list without triggering the file-size limit.
  @valid_png <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, "IHDR", 0, 0, 0, 1, 0,
               0, 0, 1, 8, 2, 0, 0, 0, 0x90, 0x77, 0x53, 0xDE>>

  setup :setup_dashboard_user_with_theme

  describe "background image upload" do
    test "a successful upload pushes upload-complete so the AutoUpload hook clears the picker",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/theme")

      view
      |> element("button[phx-value-theme='1']", "Customize Style")
      |> render_click()

      # Switch to the image tab, which renders the upload form.
      view
      |> element("button[phx-click='theme:set_browsing_type'][phx-value-type='image']")
      |> render_click()

      image = %{
        last_modified: System.system_time(:millisecond),
        name: "background.png",
        content: @valid_png,
        type: "image/png"
      }

      view
      |> file_input("#theme-background-image-form", :background_image, [image])
      |> render_upload("background.png")

      assert_push_event(view, "upload-complete", %{})
    end

    test "an image upload replaces an uploaded video and removes its file",
         %{conn: conn, profile: profile} do
      upload_root =
        Path.join(System.tmp_dir!(), "tymeslot_uploads_#{System.unique_integer([:positive])}")

      original_root = Application.get_env(:tymeslot, :upload_directory)
      Application.put_env(:tymeslot, :upload_directory, upload_root)

      on_exit(fn ->
        Application.put_env(:tymeslot, :upload_directory, original_root)
        File.rm_rf(upload_root)
      end)

      video_rel = "themes/#{profile.id}/1/videos/old.mp4"
      video_abs = Storage.build_theme_file_path(video_rel)
      File.mkdir_p!(Path.dirname(video_abs))
      File.write!(video_abs, "data")

      {:ok, _customization} =
        ThemeCustomizations.create_theme_customization(profile.id, "1", %{
          "background_type" => "video",
          "background_value" => "custom",
          "background_video_path" => video_rel
        })

      {:ok, view, _html} = live(conn, ~p"/dashboard/theme")

      view
      |> element("button[phx-value-theme='1']", "Customize Style")
      |> render_click()

      view
      |> element("button[phx-click='theme:set_browsing_type'][phx-value-type='image']")
      |> render_click()

      image = %{
        last_modified: System.system_time(:millisecond),
        name: "background.png",
        content: @valid_png,
        type: "image/png"
      }

      view
      |> file_input("#theme-background-image-form", :background_image, [image])
      |> render_upload("background.png")

      assert_push_event(view, "upload-complete", %{})

      saved = ThemeCustomizations.get_by_profile_and_theme(profile.id, "1")
      assert saved.background_type == "image"
      assert saved.background_image_path =~ "themes/#{profile.id}/1/images/"
      assert saved.background_video_path == nil
      refute File.exists?(video_abs)
    end
  end
end
