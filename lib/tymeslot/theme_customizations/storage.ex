defmodule Tymeslot.ThemeCustomizations.Storage do
  @moduledoc """
  Handles filesystem-related operations for theme customization assets.
  Owns directory management, path building, and file storage.
  """

  alias Tymeslot.Media.ImageMetadata
  alias Tymeslot.Media.Uploads
  alias Tymeslot.Media.VideoMetadata
  alias Tymeslot.Utils.MediaValidator

  @type file_upload :: %{required(:path) => Path.t(), optional(:filename) => String.t()}

  @invalid_format %{image: :invalid_image_format, video: :invalid_video_format}

  @doc """
  Builds an absolute file system path from a stored relative path.
  """
  @spec build_theme_file_path(String.t()) :: String.t()
  def build_theme_file_path(relative_path) do
    base_dir = get_upload_base_directory()
    Path.join(base_dir, relative_path)
  end

  @doc """
  Returns the base directory used for uploads.
  """
  @spec get_upload_base_directory() :: String.t()
  def get_upload_base_directory do
    Uploads.root()
  end

  @doc """
  Removes a profile's whole theme upload directory: every theme's images,
  videos and transcoded variants, whether or not a row still references them.
  """
  @spec delete_profile_directory(pos_integer()) :: :ok | {:error, File.posix(), Path.t()}
  def delete_profile_directory(profile_id) when is_integer(profile_id) do
    case File.rm_rf(
           Path.join([get_upload_base_directory(), "themes", Integer.to_string(profile_id)])
         ) do
      {:ok, _removed} -> :ok
      {:error, reason, failed_path} -> {:error, reason, failed_path}
    end
  end

  @doc """
  Stores a background image file and returns {:ok, relative_path}.

  The image is re-encoded without its metadata (see
  `Tymeslot.Media.ImageMetadata`) in place at `temp_path`, which the caller
  hands over: it is moved into the upload directory.
  """
  @spec store_background_image(integer(), String.t(), file_upload()) ::
          {:ok, String.t()} | {:error, term()}
  def store_background_image(profile_id, theme_id, %{path: temp_path}) do
    if MediaValidator.valid_image_file?(temp_path) do
      dest_dir = theme_directory(profile_id, theme_id, "images")

      with {:ok, extension} <- detected_extension(:image, ImageMetadata.extension(temp_path)),
           :ok <- ImageMetadata.strip(temp_path, temp_path, extension),
           {:ok, sanitized_filename} <-
             Uploads.store_atomically(
               temp_path,
               dest_dir,
               Uploads.stored_name(extension),
               %{operation: :store_background_image, profile_id: profile_id, theme_id: theme_id}
             ) do
        {:ok, Path.join(dest_dir, sanitized_filename)}
      end
    else
      {:error, :invalid_image_format}
    end
  end

  @doc """
  Stores a background video file and returns {:ok, relative_path}.

  The video's metadata is removed (see `Tymeslot.Media.VideoMetadata`) in
  place at `temp_path`, which the caller hands over: it is moved into the
  upload directory. A file that is not an MP4 or WebM the stripper can read
  to the end is refused as `:invalid_video_format`.
  """
  @spec store_background_video(integer(), String.t(), file_upload()) ::
          {:ok, String.t()} | {:error, term()}
  def store_background_video(profile_id, theme_id, %{path: temp_path}) do
    if MediaValidator.valid_video_file?(temp_path) do
      dest_dir = theme_directory(profile_id, theme_id, "videos")

      with {:ok, extension} <- detected_extension(:video, VideoMetadata.extension(temp_path)),
           {:ok, _stripped_or_unchanged} <- strip_video(temp_path),
           {:ok, sanitized_filename} <-
             Uploads.store_atomically(
               temp_path,
               dest_dir,
               Uploads.stored_name(extension),
               %{operation: :store_background_video, profile_id: profile_id, theme_id: theme_id}
             ) do
        {:ok, Path.join(dest_dir, sanitized_filename)}
      end
    else
      {:error, :invalid_video_format}
    end
  end

  # Relative to the upload root, as `Uploads.store_atomically/4` takes it and
  # as the row stores it.
  defp theme_directory(profile_id, theme_id, type),
    do: Path.join(["themes", to_string(profile_id), theme_id, type])

  # The file is named after the format its bytes are, which must also be one
  # this kind of background accepts (an animated GIF is not a background).
  defp detected_extension(kind, {:ok, extension}) do
    if extension in Uploads.allowed_extensions(kind),
      do: {:ok, extension},
      else: {:error, Map.fetch!(@invalid_format, kind)}
  end

  defp detected_extension(kind, {:error, _unrecognised}),
    do: {:error, Map.fetch!(@invalid_format, kind)}

  defp strip_video(path) do
    case VideoMetadata.strip(path) do
      {:ok, result} ->
        {:ok, result}

      {:error, reason} when reason in [:unsupported_container, :malformed] ->
        {:error, :invalid_video_format}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
