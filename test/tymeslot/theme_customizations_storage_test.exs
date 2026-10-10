defmodule Tymeslot.ThemeCustomizationsStorageTest do
  use Tymeslot.DataCase, async: false
  @moduletag :utils

  alias Tymeslot.Test.MediaFixtures
  alias Tymeslot.ThemeCustomizations.Storage

  setup do
    upload_root =
      Path.join(System.tmp_dir!(), "tymeslot_uploads_#{System.unique_integer([:positive])}")

    original_root = Application.get_env(:tymeslot, :upload_directory)

    Application.put_env(:tymeslot, :upload_directory, upload_root)

    on_exit(fn ->
      Application.put_env(:tymeslot, :upload_directory, original_root)
      File.rm_rf(upload_root)
    end)

    %{upload_root: upload_root}
  end

  describe "Storage module" do
    test "build_theme_file_path/1 creates full path", %{upload_root: upload_root} do
      relative_path = "themes/1/images/background.jpg"
      full_path = Storage.build_theme_file_path(relative_path)

      assert full_path =~ "themes/1/images/background.jpg"
      assert String.starts_with?(full_path, Storage.get_upload_base_directory())
      assert String.starts_with?(full_path, upload_root)
    end

    test "get_upload_base_directory/0 returns configured directory", %{upload_root: upload_root} do
      base_dir = Storage.get_upload_base_directory()

      assert base_dir == upload_root
    end

    test "store_background_image/3 returns error tuple when directory creation fails" do
      # Point upload dir at a read-only location so the store cannot create its directory
      readonly = Path.join(System.tmp_dir!(), "tymeslot_ro_#{:rand.uniform(100_000)}")
      File.mkdir_p!(readonly)
      File.chmod!(readonly, 0o444)

      original_dir = Application.get_env(:tymeslot, :upload_directory)
      Application.put_env(:tymeslot, :upload_directory, readonly)

      temp_file = MediaFixtures.temp_copy!("gps.webp")

      try do
        result = Storage.store_background_image(1, "1", %{path: temp_file, filename: "bg.webp"})
        assert {:error, :eacces} = result
      after
        Application.put_env(:tymeslot, :upload_directory, original_dir)
        File.chmod!(readonly, 0o755)
        File.rm_rf!(readonly)
      end
    end

    test "store_background_image/3 returns error for non-existent temp file" do
      result =
        Storage.store_background_image(1, "1", %{
          path: "/nonexistent/temp/file.jpg",
          filename: "test.jpg"
        })

      assert result == {:error, :invalid_image_format}
    end

    test "store_background_image/3 stores the image without its EXIF location" do
      temp_file = MediaFixtures.temp_copy!("gps.webp")

      assert {:ok, stored_path} =
               Storage.store_background_image(1, "1", %{path: temp_file, filename: "bg.webp"})

      assert stored_path =~ "themes/1/1/images"
      full_path = Storage.build_theme_file_path(stored_path)
      assert MediaFixtures.image_metadata_fields(File.read!(full_path)) == []
      refute File.read!(full_path) =~ "Model-X"
    end

    test "store_background_image/3 refuses a file that only has image magic bytes" do
      temp_file = Path.join(System.tmp_dir!(), "test_image_#{System.unique_integer([:positive])}")
      File.write!(temp_file, "GIF89a" <> "fake image data")
      on_exit(fn -> File.rm(temp_file) end)

      assert {:error, :invalid_image_format} =
               Storage.store_background_image(1, "1", %{path: temp_file, filename: "bg.gif"})
    end

    test "store_background_video/3 stores the video without its location" do
      temp_file = MediaFixtures.temp_copy!("gps.mp4")

      assert {:ok, stored_path} =
               Storage.store_background_video(1, "1", %{path: temp_file, filename: "test.mp4"})

      assert stored_path =~ "themes/1/1/videos"
      stored = stored_path |> Storage.build_theme_file_path() |> File.read!()
      assert byte_size(stored) == byte_size(MediaFixtures.read!("gps.mp4"))
      refute stored =~ <<0xA9, "xyz">>
      refute stored =~ "location.ISO6709"
    end

    test "store_background_video/3 refuses a container whose metadata cannot be stripped" do
      temp_file = Path.join(System.tmp_dir!(), "test_video_#{System.unique_integer([:positive])}")
      # AVI is neither MP4 nor WebM.
      File.write!(temp_file, "RIFF" <> <<100::little-32>> <> "AVI LIST")
      on_exit(fn -> File.rm(temp_file) end)

      assert {:error, :invalid_video_format} =
               Storage.store_background_video(1, "1", %{path: temp_file, filename: "clip.mp4"})
    end

    test "store_background_video/3 names a WebM sent as .mp4 after what it is" do
      temp_file = MediaFixtures.temp_copy!("gps.webm")

      assert {:ok, stored_path} =
               Storage.store_background_video(1, "1", %{path: temp_file, filename: "clip.mp4"})

      assert Path.basename(stored_path) =~ ~r/\A[0-9a-f-]{36}\.webm\z/
      assert File.exists?(Storage.build_theme_file_path(stored_path))
    end

    test "store_background_video/3 refuses junk whose first byte is the MPEG-TS sync byte" do
      temp_file = Path.join(System.tmp_dir!(), "test_video_#{System.unique_integer([:positive])}")
      File.write!(temp_file, <<0x47>> <> :binary.copy(<<0xFF>>, 1_000))
      on_exit(fn -> File.rm(temp_file) end)

      assert {:error, :invalid_video_format} =
               Storage.store_background_video(1, "1", %{path: temp_file, filename: "clip.mp4"})
    end

    test "store_background_image/3 names a PNG sent as .jpg after what it is" do
      temp_file = MediaFixtures.temp_copy!("gps.png")

      assert {:ok, stored_path} =
               Storage.store_background_image(1, "1", %{path: temp_file, filename: "bg.jpg"})

      assert Path.basename(stored_path) =~ ~r/\A[0-9a-f-]{36}\.png\z/
      stored = stored_path |> Storage.build_theme_file_path() |> File.read!()
      assert <<137, 80, 78, 71, _rest::binary>> = stored
      assert MediaFixtures.image_metadata_fields(stored) == []
    end

    test "store_background_image/3 refuses an animated GIF sent under an accepted name" do
      temp_file = MediaFixtures.temp_copy!("animated.gif")

      assert {:error, :invalid_image_format} =
               Storage.store_background_image(1, "1", %{path: temp_file, filename: "bg.png"})
    end

    # The code default, "uploads", is relative to the working directory.
    @tag :tmp_dir
    test "store_background_video/3 stores under a relative upload root at the path it returns",
         %{tmp_dir: tmp_dir} do
      Application.put_env(:tymeslot, :upload_directory, Path.relative_to_cwd(tmp_dir))
      temp_file = MediaFixtures.temp_copy!("gps.mp4")

      assert {:ok, stored_path} =
               Storage.store_background_video(1, "1", %{path: temp_file, filename: "clip.mp4"})

      assert File.exists?(Path.join(tmp_dir, stored_path))
      refute File.exists?(Path.join([tmp_dir, Path.relative_to_cwd(tmp_dir), stored_path]))
    end
  end
end
