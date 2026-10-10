defmodule Tymeslot.ThemeCustomizations.Backgrounds do
  @moduledoc """
  Pure functions for background operations and transformations.
  Handles background type changes.
  """

  @doc """
  Applies a background selection to a customization, updating type and value.
  """
  @spec apply_background_selection(term(), String.t(), String.t()) :: term()
  def apply_background_selection(customization, type, value) do
    clear_conflicting_backgrounds(
      %{
        customization
        | background_type: type,
          background_value: value
      },
      type
    )
  end

  @doc """
  Clears background paths that conflict with the new background type.
  """
  @spec clear_conflicting_backgrounds(term(), String.t()) :: term()
  def clear_conflicting_backgrounds(customization, new_type) do
    case new_type do
      "image" when customization.background_value != "custom" ->
        # Clear custom image path when selecting preset image
        %{customization | background_image_path: nil}

      "video" when customization.background_value != "custom" ->
        # Clear custom video path when selecting preset video
        %{customization | background_video_path: nil}

      "gradient" ->
        # Clear both image and video paths when selecting gradient
        %{customization | background_image_path: nil, background_video_path: nil}

      "color" ->
        # Clear both image and video paths when selecting color
        %{customization | background_image_path: nil, background_video_path: nil}

      _other_type ->
        customization
    end
  end
end
