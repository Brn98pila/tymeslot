defmodule Tymeslot.ThemeCustomizations.Assets do
  @moduledoc """
  Attaches an uploaded file to a theme customisation.

  Generic over the theme spec's `asset_fields/0`: a field the theme does not
  declare is refused. For a declared field this stores the file according to
  the field's kind, saves it as the custom background (clearing the other
  upload, whose file the save then deletes), and for a video queues the
  transcoding job, marking the record `failed` if the job cannot be queued.
  Errors come back as translated, user-facing messages.

  The web layer calls this from inside `consume_uploaded_entries/3`, because
  the temporary upload is deleted as soon as that callback returns.
  """
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.ThemeCustomizations
  alias Tymeslot.ThemeCustomizations.Storage
  alias Tymeslot.ThemeCustomizations.ThemeCustomizationSchema
  alias Tymeslot.Workers.VideoTranscoder

  @type upload :: %{path: String.t(), filename: String.t()}
  @type result :: {:ok, ThemeCustomizationSchema.t()} | {:error, String.t()}

  @doc """
  Stores `upload` for the theme's asset field `field` (an upload column such as
  `:background_image_path`) and saves it on the profile's customisation.
  """
  @spec attach_asset(pos_integer(), String.t(), atom(), upload()) :: result()
  def attach_asset(profile_id, theme_id, field, upload) do
    fields = ThemeCustomizations.asset_fields(theme_id)

    case Keyword.fetch(fields, field) do
      {:ok, kind} ->
        attach(kind, profile_id, theme_id, field, other_fields(fields, field), upload)

      :error ->
        {:error, option_unavailable()}
    end
  end

  defp attach(:image, profile_id, theme_id, field, cleared, upload) do
    with {:ok, path} <- store(:image, profile_id, theme_id, upload) do
      save(profile_id, theme_id, background_attrs("image", field, path, cleared))
    end
  end

  defp attach(:video, profile_id, theme_id, field, cleared, upload) do
    with :ok <- ensure_transcoder(),
         {:ok, path} <- store(:video, profile_id, theme_id, upload),
         {:ok, customization} <-
           save(
             profile_id,
             theme_id,
             "video"
             |> background_attrs(field, path, cleared)
             |> Map.put("video_processing", "pending")
           ) do
      queue_transcoding(customization, Map.fetch!(customization, field))
    end
  end

  # An upload replaces whatever upload the background held before: clearing
  # the other columns makes the save delete their files.
  defp background_attrs(type, field, path, cleared) do
    Map.merge(
      Map.new(cleared, &{Atom.to_string(&1), nil}),
      %{
        "background_type" => type,
        "background_value" => "custom",
        Atom.to_string(field) => path
      }
    )
  end

  defp other_fields(fields, field), do: fields |> Keyword.keys() |> List.delete(field)

  defp store(:image, profile_id, theme_id, upload) do
    case Storage.store_background_image(profile_id, theme_id, upload) do
      {:ok, path} ->
        {:ok, path}

      {:error, :invalid_image_format} ->
        {:error,
         dgettext(
           "dashboard_appearance",
           "Invalid image format. Please upload a valid image file."
         )}

      {:error, _reason} ->
        {:error, upload_failed()}
    end
  end

  defp store(:video, profile_id, theme_id, upload) do
    case Storage.store_background_video(profile_id, theme_id, upload) do
      {:ok, path} ->
        {:ok, path}

      {:error, :invalid_video_format} ->
        {:error,
         dgettext(
           "dashboard_appearance",
           "Invalid video format. Please upload a valid video file."
         )}

      {:error, _reason} ->
        {:error, upload_failed()}
    end
  end

  defp save(profile_id, theme_id, attrs) do
    case ThemeCustomizations.upsert_theme_customization(profile_id, theme_id, attrs) do
      {:ok, customization} ->
        {:ok, customization}

      {:error, _changeset} ->
        {:error,
         dgettext(
           "dashboard_appearance",
           "Could not save your theme customization. Please try again."
         )}
    end
  end

  # ffmpeg is detected at transcode time in the worker; without this check the
  # upload would report success and then fail silently in the background.
  defp ensure_transcoder do
    if transcoder().available?() do
      :ok
    else
      {:error,
       dgettext(
         "dashboard_appearance",
         "Video processing is unavailable on this server because ffmpeg is not installed. Install ffmpeg or use a background image instead."
       )}
    end
  end

  defp queue_transcoding(customization, video_path) do
    case VideoTranscoder.enqueue(customization.id, video_path) do
      {:ok, _job} ->
        {:ok, customization}

      {:error, _reason} ->
        # Only the status changes: the saved video stays, so the user can see
        # what failed and upload again.
        _marked =
          ThemeCustomizations.upsert_theme_customization(
            customization.profile_id,
            customization.theme_id,
            %{"video_processing" => "failed"}
          )

        {:error,
         dgettext(
           "dashboard_appearance",
           "Your video was saved but could not be queued for processing. Please upload it again."
         )}
    end
  end

  defp upload_failed, do: dgettext("dashboard_appearance", "Upload failed")

  defp option_unavailable,
    do: dgettext("dashboard_appearance", "This option is not available for this theme.")

  # Resolved the same way as the VideoTranscoder worker, so a test stub set via
  # `config :tymeslot, :transcoder` applies to both sides.
  defp transcoder, do: Application.get_env(:tymeslot, :transcoder, Tymeslot.Media.Transcoder)
end
