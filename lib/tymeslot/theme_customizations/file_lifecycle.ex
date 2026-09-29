defmodule Tymeslot.ThemeCustomizations.FileLifecycle do
  @moduledoc """
  Side-effecting cleanup of theme background assets on the filesystem.

  Orchestrates `Storage` and `Transcoder` to delete stale background images,
  videos, and their transcoded variants when a customisation is updated,
  deleted, or has its background replaced. Which fields hold stored files, and
  of which kind, comes from the theme's customisation spec (`asset_fields/0`).
  Persistence is handled by the caller; this module only deals with files.
  """

  require Logger

  alias Tymeslot.Media.Transcoder
  alias Tymeslot.ThemeCustomizations.DataTransform
  alias Tymeslot.ThemeCustomizations.Spec
  alias Tymeslot.ThemeCustomizations.Storage
  alias Tymeslot.ThemeCustomizations.ThemeCustomizationSchema

  # The upload settings a spec's `asset_fields/0` names for the shipped themes.
  @type cleanup_entry :: %{
          optional(:background_image_path) => String.t() | nil,
          optional(:background_video_path) => String.t() | nil
        }

  @doc """
  Deletes the files an update replaced: every asset field of the theme's spec
  whose stored path changed between the record before and after the update.
  Replaced videos also lose their transcoded variants.
  """
  @spec cleanup_replaced_files(ThemeCustomizationSchema.t(), ThemeCustomizationSchema.t()) :: :ok
  def cleanup_replaced_files(
        %ThemeCustomizationSchema{} = previous,
        %ThemeCustomizationSchema{} = updated
      ) do
    context = %{
      profile_id: previous.profile_id,
      theme_id: previous.theme_id,
      operation: "theme_update"
    }

    previous.theme_id
    |> asset_fields()
    |> Enum.each(fn {field, kind} ->
      old_path = setting(previous, field)

      if old_path && old_path != setting(updated, field) do
        delete_asset(old_path, kind, context, "old_#{kind}")
      end
    end)
  end

  @doc """
  Deletes every stored file of a deleted customisation, including transcoded
  video variants.
  """
  @spec cleanup_all_files(ThemeCustomizationSchema.t()) :: :ok
  def cleanup_all_files(%ThemeCustomizationSchema{} = customization) do
    context = %{
      profile_id: customization.profile_id,
      theme_id: customization.theme_id,
      operation: "theme_delete"
    }

    customization.theme_id
    |> asset_fields()
    |> Enum.each(fn {field, kind} ->
      if path = setting(customization, field), do: delete_asset(path, kind, context, "#{kind}")
    end)
  end

  @doc """
  Legacy cleanup over a cleanup entry from
  `Backgrounds.determine_cleanup_files/2`: deletes the referenced image and
  video files (no variant handling).
  """
  @spec cleanup_old_backgrounds(cleanup_entry()) :: :ok
  def cleanup_old_backgrounds(customization) do
    context = %{operation: "legacy_cleanup"}

    if image_path = Map.get(customization, :background_image_path) do
      delete_file(image_path, context, "image")
    end

    if video_path = Map.get(customization, :background_video_path) do
      delete_file(video_path, context, "video")
    end

    :ok
  end

  # --- Private helpers ----------------------------------------------------

  defp asset_fields(theme_id), do: Spec.for_theme(theme_id).asset_fields()

  defp setting(customization, field),
    do: Map.get(DataTransform.to_settings(customization), Atom.to_string(field))

  defp delete_asset(path, :image, context, label), do: delete_file(path, context, label)

  defp delete_asset(path, :video, context, label) do
    delete_file(path, context, label)
    delete_video_variants(path, context, label <> "_variant")
  end

  defp delete_file(relative_path, context, file_type) do
    relative_path
    |> Storage.build_theme_file_path()
    |> safe_delete(Map.put(context, :file_type, file_type))
  end

  # Best-effort filesystem delete: never fails the calling cleanup, a missing
  # file is treated as already-gone. Kept in the domain layer so this module
  # has no dependency on the web layer.
  @spec safe_delete(String.t(), map()) :: :ok
  defp safe_delete(absolute_path, context) do
    case File.rm(absolute_path) do
      :ok ->
        Logger.info("File deleted successfully", file_path: absolute_path, context: context)
        :ok

      {:error, :enoent} ->
        Logger.debug("File deletion skipped - file not found",
          file_path: absolute_path,
          context: context
        )

        :ok

      {:error, reason} ->
        Logger.warning("File deletion failed",
          file_path: absolute_path,
          reason: reason,
          context: context
        )

        :ok
    end
  end

  defp delete_video_variants(video_path, context, file_type) do
    video_path
    |> Transcoder.derive_variant_paths()
    |> Enum.each(&delete_file(&1, context, file_type))
  end
end
