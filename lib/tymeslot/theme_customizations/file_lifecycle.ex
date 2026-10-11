defmodule Tymeslot.ThemeCustomizations.FileLifecycle do
  @moduledoc """
  Side-effecting cleanup of theme background assets on the filesystem.

  Orchestrates `Tymeslot.Media.Uploads` and `Transcoder` to delete stale
  background images, videos, and their transcoded variants when a
  customisation is updated or deleted. Persistence is handled by the
  caller — this module only deals with files.
  """

  alias Tymeslot.Media.Transcoder
  alias Tymeslot.Media.Uploads
  alias Tymeslot.ThemeCustomizations.ThemeCustomizationSchema

  @doc """
  Deletes the background files an update stopped referencing.

  Compares the paths stored before the update with the ones stored after it,
  so a field the update left untouched keeps its file and a field set to nil
  or to a new path loses the old one. Replaced videos also have their
  transcoded variants removed.
  """
  @spec cleanup_replaced_files(ThemeCustomizationSchema.t(), ThemeCustomizationSchema.t()) ::
          :ok
  def cleanup_replaced_files(
        %ThemeCustomizationSchema{} = previous,
        %ThemeCustomizationSchema{} = updated
      ) do
    context = %{
      profile_id: previous.profile_id,
      theme_id: previous.theme_id,
      operation: "theme_update"
    }

    if replaced?(previous.background_image_path, updated.background_image_path) do
      delete_file(previous.background_image_path, context, "old_image")
    end

    if replaced?(previous.background_video_path, updated.background_video_path) do
      delete_file(previous.background_video_path, context, "old_video")
      delete_video_variants(previous.background_video_path, context, "old_video_variant")
    end

    :ok
  end

  @doc """
  Cleans up all background files associated with a deleted customisation,
  including transcoded video variants.
  """
  @spec cleanup_all_files(ThemeCustomizationSchema.t()) :: :ok
  def cleanup_all_files(%ThemeCustomizationSchema{} = customization) do
    context = %{
      profile_id: customization.profile_id,
      theme_id: customization.theme_id,
      operation: "theme_delete"
    }

    if customization.background_image_path do
      delete_file(customization.background_image_path, context, "image")
    end

    if customization.background_video_path do
      delete_file(customization.background_video_path, context, "video")
      delete_video_variants(customization.background_video_path, context, "video_variant")
    end

    :ok
  end

  # --- Private helpers ----------------------------------------------------

  defp replaced?(nil, _new), do: false
  defp replaced?(old, new), do: old != new

  defp delete_file(relative_path, context, file_type) do
    Uploads.delete_safely(relative_path, Map.put(context, :file_type, file_type))
  end

  defp delete_video_variants(video_path, context, file_type) do
    video_path
    |> Transcoder.derive_variant_paths()
    |> Enum.each(&delete_file(&1, context, file_type))
  end
end
