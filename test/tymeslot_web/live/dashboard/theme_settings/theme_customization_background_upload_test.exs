defmodule TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomizationBackgroundUploadTest do
  @moduledoc """
  Verifies a successful background image upload in the theme customizer
  pushes "upload-complete" so the `AutoUpload` hook clears the file picker,
  mirroring the avatar upload fixes (dashboard and onboarding), and that what
  is published carries none of the uploaded file's metadata.
  """

  use TymeslotWeb.LiveCase, async: false

  use Oban.Testing, repo: Tymeslot.Repo

  import Mox

  alias Tymeslot.Media.Transcoder
  alias Tymeslot.Media.TranscoderMock
  alias Tymeslot.Media.Uploads
  alias Tymeslot.Test.MediaFixtures
  alias Tymeslot.ThemeCustomizations
  alias Tymeslot.Workers.VideoTranscoder

  @moduletag :themes
  @moduletag :live

  import Tymeslot.DashboardTestHelpers

  # Complete and decodable: a stored image is re-encoded, so magic bytes
  # alone are refused.
  @valid_png MediaFixtures.png()

  setup :setup_dashboard_user_with_theme
  setup :verify_on_exit!

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

    test "publishes a WebP background without its EXIF location", %{
      conn: conn,
      profile: profile
    } do
      {:ok, view, _html} = live(conn, ~p"/dashboard/theme")
      open_image_tab(view)

      image = %{
        last_modified: System.system_time(:millisecond),
        name: "garden.webp",
        content: MediaFixtures.read!("gps.webp"),
        type: "image/webp"
      }

      view
      |> file_input("#theme-background-image-form", :background_image, [image])
      |> render_upload("garden.webp")

      assert_push_event(view, "upload-complete", %{})

      customization = ThemeCustomizations.get_by_profile_and_theme(profile.id, "1")
      response = get(build_conn(), "/uploads/" <> customization.background_image_path)
      assert response.status == 200
      assert MediaFixtures.image_metadata_fields(response.resp_body) == []
      refute response.resp_body =~ "Model-X"
    end

    test "refuses an image over 40 megapixels and says how large it may be", %{
      conn: conn,
      profile: profile
    } do
      {:ok, view, _html} = live(conn, ~p"/dashboard/theme")
      open_image_tab(view)

      image = %{
        last_modified: System.system_time(:millisecond),
        name: "huge.png",
        content: MediaFixtures.png_declaring(20_000, 20_000),
        type: "image/png"
      }

      view
      |> file_input("#theme-background-image-form", :background_image, [image])
      |> render_upload("huge.png")

      assert render(view) =~
               "This image is too large (400.0 megapixels). " <>
                 "Please upload an image of at most 40 megapixels."

      refute match?(
               %{background_image_path: path} when is_binary(path),
               ThemeCustomizations.get_by_profile_and_theme(profile.id, "1")
             )
    end
  end

  describe "background video upload" do
    test "refuses a QuickTime file", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/theme")

      view
      |> element("button[phx-value-theme='1']", "Customize Style")
      |> render_click()

      view
      |> element("button[phx-click='theme:set_browsing_type'][phx-value-type='video']")
      |> render_click()

      video = %{
        last_modified: System.system_time(:millisecond),
        name: "clip.mov",
        content: <<0, 0, 0, 20, "ftypqt  ", 0, 0, 0, 0, "qt  ">>,
        type: "video/quicktime"
      }

      assert {:error, [[_ref, :not_accepted]]} =
               view
               |> file_input("#theme-background-video-form", :background_video, [video])
               |> render_upload("clip.mov")
    end
  end

  describe "background video upload journey" do
    setup do
      stub(TranscoderMock, :available?, fn -> true end)
      :ok
    end

    test "stores the video under its detected type, keeps the image, replaces the old video and transcodes the new one",
         %{conn: conn, profile: profile} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/theme")
      open_image_tab(view)

      upload(view, :background_image, "garden.webp", MediaFixtures.read!("gps.webp"))
      image_path = stored(profile).background_image_path
      assert File.exists?(on_disk(image_path))

      open_video_tab(view)

      # A WebM sent under an MP4 name.
      upload(view, :background_video, "clip.mp4", MediaFixtures.read!("gps.webm"))
      first = stored(profile)
      assert Path.basename(first.background_video_path) =~ ~r/\A[0-9a-f-]{36}\.webm\z/
      assert first.video_processing == "pending"
      assert File.exists?(on_disk(first.background_video_path))
      assert File.exists?(on_disk(image_path))

      # What the first video's transcode wrote beside it.
      first_variants =
        for variant <- Transcoder.derive_variant_paths(first.background_video_path) do
          path = on_disk(variant)
          File.write!(path, "variant")
          path
        end

      upload(view, :background_video, "clip.mp4", MediaFixtures.read!("gps.mp4"))
      second = stored(profile)
      assert Path.extname(second.background_video_path) == ".mp4"
      refute File.exists?(on_disk(first.background_video_path))
      refute Enum.any?(first_variants, &File.exists?/1)
      assert File.exists?(on_disk(image_path))

      args = %{
        "theme_customization_id" => second.id,
        "video_path" => second.background_video_path
      }

      assert_enqueued(worker: VideoTranscoder, args: args)

      expect(TranscoderMock, :transcode, length(Transcoder.variant_definitions()), fn _src,
                                                                                      _out,
                                                                                      _opts ->
        :ok
      end)

      assert :ok = perform_job(VideoTranscoder, args)
      assert stored(profile).video_processing == "completed"
    end
  end

  defp upload(view, upload_key, name, content) do
    form = "#theme-" <> String.replace(to_string(upload_key), "_", "-") <> "-form"

    entry = %{
      last_modified: System.system_time(:millisecond),
      name: name,
      content: content,
      type: MIME.from_path(name)
    }

    view
    |> file_input(form, upload_key, [entry])
    |> render_upload(name)

    assert_push_event(view, "upload-complete", %{})
  end

  defp stored(profile), do: ThemeCustomizations.get_by_profile_and_theme(profile.id, "1")

  defp on_disk(relative), do: Path.join(Uploads.root(), relative)

  defp open_video_tab(view) do
    view
    |> element("button[phx-click='theme:set_browsing_type'][phx-value-type='video']")
    |> render_click()
  end

  defp open_image_tab(view) do
    view
    |> element("button[phx-value-theme='1']", "Customize Style")
    |> render_click()

    view
    |> element("button[phx-click='theme:set_browsing_type'][phx-value-type='image']")
    |> render_click()
  end
end
