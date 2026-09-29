defmodule Tymeslot.Utils.MediaValidator do
  @moduledoc """
  Utility for validating media files (images and videos) using magic bytes.
  """

  # Major brands of an ISO base media file that name a video file: the ISO
  # base media versions, MP4 v1/v2, H.264 MP4, QuickTime, iTunes video,
  # MPEG-DASH segments and 3GPP video. Still-image and audio brands in the same
  # family (`heic`, `mif1`, `avif`, `M4A `, ...) are deliberately absent.
  @video_brands ~w(isom iso2 iso3 iso4 iso5 iso6 mp41 mp42 avc1 dash 3gp4 3gp5 3gp6) ++
                  ["qt  ", "M4V ", "M4VH", "M4VP"]

  @doc """
  Validates if a binary is a supported image format using ExImageInfo.
  """
  @spec valid_image?(binary()) :: boolean()
  def valid_image?(binary) when is_binary(binary) do
    case ExImageInfo.info(binary) do
      {mime, _width, _height, _variant} when is_binary(mime) -> true
      _other -> false
    end
  end

  @spec valid_image?(any()) :: boolean()
  def valid_image?(_other), do: false

  @spec valid_png?(binary()) :: boolean()
  defp valid_png?(binary) when is_binary(binary) do
    case ExImageInfo.info(binary) do
      {"image/png", _width, _height, _variant} -> true
      _other -> false
    end
  end

  @doc """
  Validates if a file at the given path is a PNG image.
  """
  @spec valid_png_file?(String.t()) :: boolean()
  def valid_png_file?(path) when is_binary(path) do
    case read_header(path) do
      {:ok, binary} -> valid_png?(binary)
      _other -> false
    end
  end

  @doc """
  Validates if a binary is a supported video format using magic bytes.

  Recognises only the containers the video upload allowlist admits
  (`.mp4`, `.mov`, `.webm`): Matroska/WebM (the EBML header), and the ISO
  base media family (MP4 and QuickTime) when the `ftyp` box's major brand is
  a video brand. The family also holds still images and audio (HEIC, AVIF,
  M4A), which carry brands of their own and are refused. So is anything
  else, whatever its name: a GIF or an image renamed `.mp4` is never stored,
  served as a background video or queued for transcoding.
  """
  @spec valid_video?(binary()) :: boolean()
  def valid_video?(binary) when is_binary(binary) do
    # We only need the first 16 bytes for magic byte validation
    header = binary_part(binary, 0, min(byte_size(binary), 16))
    video_header?(header)
  end

  @spec valid_video?(any()) :: boolean()
  def valid_video?(_other), do: false

  # MP4 / MOV: an ftyp box at offset 4 whose major brand is a video brand.
  defp video_header?(<<_size::binary-size(4), "ftyp", brand::binary-size(4), _rest::binary>>),
    do: brand in @video_brands

  # WebM / MKV: 1A 45 DF A3
  defp video_header?(<<0x1A, 0x45, 0xDF, 0xA3, _rest::binary>>), do: true

  defp video_header?(_other), do: false

  @doc """
  Validates if a file at the given path is a supported image format.
  """
  @spec valid_image_file?(String.t()) :: boolean()
  def valid_image_file?(path) when is_binary(path) do
    case read_header(path) do
      {:ok, binary} -> valid_image?(binary)
      _other -> false
    end
  end

  @doc """
  Validates if a file at the given path is a supported video format.
  """
  @spec valid_video_file?(String.t()) :: boolean()
  def valid_video_file?(path) when is_binary(path) do
    case read_header(path) do
      {:ok, binary} -> valid_video?(binary)
      _other -> false
    end
  end

  # Reads up to 2048 header bytes from `path`, always closing the handle,
  # including when `IO.binread/2` returns `:eof` or `{:error, _}`.
  @spec read_header(String.t()) :: {:ok, binary()} | {:error, term()}
  defp read_header(path) do
    open_result =
      File.open(path, [:read, :binary], fn file ->
        case IO.binread(file, 2048) do
          binary when is_binary(binary) -> binary
          other -> {:error, other}
        end
      end)

    case open_result do
      {:ok, {:error, reason}} -> {:error, reason}
      {:ok, binary} -> {:ok, binary}
      {:error, reason} -> {:error, reason}
    end
  end
end
