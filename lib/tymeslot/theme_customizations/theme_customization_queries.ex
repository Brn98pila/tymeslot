defmodule Tymeslot.ThemeCustomizations.ThemeCustomizationQueries do
  @moduledoc """
  Query interface for theme customization-related database operations.
  """
  import Ecto.Query, warn: false

  alias Tymeslot.Profiles.ProfileSchema
  alias Tymeslot.Repo
  alias Tymeslot.ThemeCustomizations.ThemeCustomizationSchema

  @doc """
  Gets a theme customization by profile ID and theme ID.
  """
  @spec get_by_profile_and_theme(integer(), String.t()) :: ThemeCustomizationSchema.t() | nil
  def get_by_profile_and_theme(profile_id, theme_id) do
    Repo.get_by(ThemeCustomizationSchema, profile_id: profile_id, theme_id: theme_id)
  end

  @doc """
  Creates a theme customization.
  """
  @spec create(map()) :: {:ok, ThemeCustomizationSchema.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    %ThemeCustomizationSchema{}
    |> ThemeCustomizationSchema.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a theme customization.
  """
  @spec update(ThemeCustomizationSchema.t(), map()) ::
          {:ok, ThemeCustomizationSchema.t()} | {:error, Ecto.Changeset.t()}
  def update(%ThemeCustomizationSchema{} = customization, attrs) do
    customization
    |> ThemeCustomizationSchema.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a theme customization.
  """
  @spec delete(ThemeCustomizationSchema.t()) ::
          {:ok, ThemeCustomizationSchema.t()} | {:error, Ecto.Changeset.t()}
  def delete(%ThemeCustomizationSchema{} = customization) do
    Repo.delete(customization)
  end

  @doc """
  Gets a profile by user_id.
  Used for finding profile when given a user_id.
  """
  @spec get_profile_by_user_id(integer()) :: ProfileSchema.t() | nil
  def get_profile_by_user_id(user_id) do
    Repo.get_by(ProfileSchema, user_id: user_id)
  end

  @doc """
  Sets the video processing status, but only while `video_path` is still the
  row's background video. A transcode of a video that has since been replaced
  or removed must not report its outcome against the row.

  Returns `{:error, :replaced}` when the row no longer holds that video, or no
  longer exists.
  """
  @spec update_video_processing_status_for(integer(), String.t(), String.t()) ::
          :ok | {:error, :replaced}
  def update_video_processing_status_for(id, video_path, status) do
    query =
      from(c in ThemeCustomizationSchema,
        where: c.id == ^id and c.background_video_path == ^video_path
      )

    case Repo.update_all(query,
           set: [video_processing: status, updated_at: DateTime.utc_now(:second)]
         ) do
      {1, _rows} -> :ok
      {0, _rows} -> {:error, :replaced}
    end
  end
end
