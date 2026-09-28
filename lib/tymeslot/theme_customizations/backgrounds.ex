defmodule Tymeslot.ThemeCustomizations.Backgrounds do
  @moduledoc """
  Which stored background files a background change leaves behind. The
  changes themselves come from `Options.Background.changes/2`.
  """

  @type cleanup_file ::
          %{required(:background_image_path) => String.t()}
          | %{required(:background_video_path) => String.t()}

  @doc """
  Determines which files need cleanup when changing backgrounds.
  Returns a list of file paths that should be removed.
  """
  @spec determine_cleanup_files(term(), term()) :: [cleanup_file()]
  def determine_cleanup_files(old_customization, new_customization) do
    cleanup_files = []

    # Check if image file needs cleanup
    cleanup_files =
      if should_cleanup_image?(old_customization, new_customization) do
        [%{background_image_path: old_customization.background_image_path} | cleanup_files]
      else
        cleanup_files
      end

    # Check if video file needs cleanup
    cleanup_files =
      if should_cleanup_video?(old_customization, new_customization) do
        [%{background_video_path: old_customization.background_video_path} | cleanup_files]
      else
        cleanup_files
      end

    cleanup_files
  end

  # Private helper functions

  defp should_cleanup_image?(old_customization, new_customization) do
    # Cleanup if we had a custom image and now we don't, or the path changed
    old_customization.background_image_path &&
      (new_customization.background_image_path != old_customization.background_image_path ||
         new_customization.background_type != "image" ||
         new_customization.background_value != "custom")
  end

  defp should_cleanup_video?(old_customization, new_customization) do
    # Cleanup if we had a custom video and now we don't, or the path changed
    old_customization.background_video_path &&
      (new_customization.background_video_path != old_customization.background_video_path ||
         new_customization.background_type != "video" ||
         new_customization.background_value != "custom")
  end
end
