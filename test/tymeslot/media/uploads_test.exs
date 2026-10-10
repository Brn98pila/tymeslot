defmodule Tymeslot.Media.UploadsTest do
  # Points the global `:upload_directory` at a per-test directory.
  use ExUnit.Case, async: false

  @moduletag :security
  @moduletag :unit
  @moduletag :tmp_dir

  import ExUnit.CaptureLog
  import Tymeslot.AdminAlertsCaptureHelpers

  alias Ecto.UUID
  alias Tymeslot.Media.Uploads
  alias Tymeslot.Profiles.Avatars

  setup :capture_admin_alerts

  setup %{tmp_dir: tmp_dir} do
    root = Path.join(tmp_dir, "uploads")
    File.mkdir_p!(root)
    original = Application.get_env(:tymeslot, :upload_directory)
    Application.put_env(:tymeslot, :upload_directory, root)
    on_exit(fn -> Application.put_env(:tymeslot, :upload_directory, original) end)

    %{root: Path.expand(root), outside: Path.join(tmp_dir, "outside")}
  end

  defp write!(path, contents \\ "data") do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    path
  end

  describe "allowed_extensions/1" do
    test "avatars accept the animated and still image formats" do
      assert Uploads.allowed_extensions(:avatar) == [".jpg", ".jpeg", ".png", ".gif", ".webp"]
    end

    test "background images accept still formats only" do
      assert Uploads.allowed_extensions(:image) == [".jpg", ".jpeg", ".png", ".webp"]
    end

    test "background videos accept only the formats whose metadata is stripped" do
      assert Uploads.allowed_extensions(:video) == [".mp4", ".webm"]
    end

    test "every extension is lowercase and dot-prefixed" do
      extensions = Enum.flat_map([:avatar, :image, :video], &Uploads.allowed_extensions/1)

      assert extensions != []
      assert Enum.reject(extensions, &(&1 == String.downcase(&1))) == []
      assert Enum.reject(extensions, &String.starts_with?(&1, ".")) == []
    end
  end

  describe "max_file_size/1" do
    test "allows progressively larger files for heavier media" do
      assert Uploads.max_file_size(:avatar) < Uploads.max_file_size(:image)
      assert Uploads.max_file_size(:image) < Uploads.max_file_size(:video)
    end

    test "Avatars reads the avatar limits from here rather than keeping a second copy" do
      assert Avatars.accepted_extensions() == Uploads.allowed_extensions(:avatar)
      assert Avatars.max_file_size() == Uploads.max_file_size(:avatar)
    end
  end

  describe "root/0" do
    test "is read at call time from the configuration", %{root: root} do
      assert Path.expand(Uploads.root()) == root
    end
  end

  describe "stored_name/1" do
    test "is a fresh UUID carrying the given extension" do
      name = Uploads.stored_name(".webm")

      assert [uuid, "webm"] = String.split(name, ".")
      assert {:ok, _uuid} = UUID.cast(uuid)
      refute Uploads.stored_name(".webm") == name
    end
  end

  describe "resolve/1" do
    test "resolves a relative path under the root", %{root: root} do
      assert Uploads.resolve("avatars/1/a.png") == {:ok, Path.join(root, "avatars/1/a.png")}
    end

    test "accepts an absolute path inside the root", %{root: root} do
      path = Path.join(root, "branding/logo.png")
      assert Uploads.resolve(path) == {:ok, path}
    end

    test "refuses a relative path that climbs out of the root" do
      assert Uploads.resolve("avatars/../../outside/a.png") == {:error, :path_traversal_attempt}
    end

    test "refuses an absolute path outside the root", %{outside: outside} do
      assert Uploads.resolve(Path.join(outside, "a.png")) == {:error, :path_traversal_attempt}
    end

    test "refuses a sibling directory sharing the root's prefix", %{root: root} do
      assert Uploads.resolve(root <> "-other/a.png") == {:error, :path_traversal_attempt}
    end

    test "refuses a symlink inside the root", %{root: root, outside: outside} do
      target = write!(Path.join(outside, "secret"))
      File.ln_s!(target, Path.join(root, "link"))

      assert Uploads.resolve("link") == {:error, :path_traversal_attempt}
    end
  end

  describe "store_atomically/4" do
    test "moves the source into the directory and returns the stored name",
         %{root: root, tmp_dir: tmp_dir} do
      source = write!(Path.join(tmp_dir, "incoming"), "bytes")

      assert {:ok, "a.png"} = Uploads.store_atomically(source, "avatars/1", "a.png", %{})

      assert File.read!(Path.join(root, "avatars/1/a.png")) == "bytes"
      refute File.exists?(source)
    end

    test "creates the directory owner- and group-only", %{root: root, tmp_dir: tmp_dir} do
      source = write!(Path.join(tmp_dir, "incoming"))

      assert {:ok, _name} = Uploads.store_atomically(source, "branding", "logo.png", %{})

      assert %File.Stat{mode: mode} = File.stat!(Path.join(root, "branding"))
      assert Bitwise.band(mode, 0o777) == 0o750
    end

    test "strips directory components and unsafe characters from the name",
         %{root: root, tmp_dir: tmp_dir} do
      source = write!(Path.join(tmp_dir, "incoming"))

      assert {:ok, "x_y.png"} =
               Uploads.store_atomically(source, "avatars/1", "../../x y.png", %{})

      assert File.exists?(Path.join(root, "avatars/1/x_y.png"))
    end

    test "refuses a destination outside the root", %{outside: outside, tmp_dir: tmp_dir} do
      source = write!(Path.join(tmp_dir, "incoming"))

      assert Uploads.store_atomically(source, outside, "a.png", %{}) ==
               {:error, :path_traversal_attempt}

      refute File.exists?(Path.join(outside, "a.png"))
      assert File.exists?(source)
    end

    test "returns the error when the source is missing", %{tmp_dir: tmp_dir} do
      capture_log(fn ->
        assert {:error, :enoent} =
                 Uploads.store_atomically(Path.join(tmp_dir, "nope"), "avatars/1", "a.png", %{})
      end)
    end
  end

  describe "delete_safely/2" do
    test "deletes a file given its path relative to the root", %{root: root} do
      path = write!(Path.join(root, "avatars/1/a.png"))

      assert Uploads.delete_safely("avatars/1/a.png", %{}) == :ok
      refute File.exists?(path)
    end

    test "deletes a file given its absolute path inside the root", %{root: root} do
      path = write!(Path.join(root, "avatars/1/a.png"))

      assert Uploads.delete_safely(path, %{}) == :ok
      refute File.exists?(path)
    end

    test "treats a file already gone as deleted" do
      assert Uploads.delete_safely("avatars/1/missing.png", %{}) == :ok
      refute_received {:send_alert, _type, _payload}
    end

    test "leaves a file outside the root alone and reports it", %{outside: outside} do
      path = write!(Path.join(outside, "a.png"))

      capture_log(fn ->
        assert Uploads.delete_safely(path, %{}) == {:error, :path_traversal_attempt}
      end)

      assert File.exists?(path)
      assert_received {:send_alert, :upload_delete_failed, %{file_path: ^path}}
    end

    test "returns a failed delete instead of raising", %{root: root} do
      dir = Path.join(root, "avatars/1/not-a-file")
      File.mkdir_p!(dir)

      log =
        capture_log(fn ->
          assert {:error, reason} = Uploads.delete_safely(dir, %{})
          assert reason in [:eisdir, :eperm]
        end)

      assert log =~ "Upload delete failed"
      assert File.dir?(dir)

      # Nothing else will come back for the file, so the operator is told.
      assert_received {:send_alert, :upload_delete_failed, %{file_path: ^dir, summary: _}}
    end
  end
end
