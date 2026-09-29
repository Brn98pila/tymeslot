defmodule Tymeslot.ThemeCustomizations.Backgrounds do
  @moduledoc """
  Which stored background files a background change leaves behind. The
  changes themselves come from `Options.Background.changes/2`.
  """

  alias Tymeslot.ThemeCustomizations.DataTransform

  @type cleanup_file ::
          %{required(:background_image_path) => String.t()}
          | %{required(:background_video_path) => String.t()}

  @doc """
  Determines which files need cleanup when changing backgrounds.
  Returns a list of file paths that should be removed.
  """
  @spec determine_cleanup_files(term(), term()) :: [cleanup_file()]
  def determine_cleanup_files(old_customization, new_customization) do
    old = DataTransform.to_settings(old_customization)
    new = DataTransform.to_settings(new_customization)

    for {field, kind} <- [background_image_path: "image", background_video_path: "video"],
        path = old[Atom.to_string(field)],
        replaced?(path, Atom.to_string(field), kind, new),
        do: %{field => path}
  end

  # A stored upload is left behind when the new background no longer names it:
  # a different path, another kind, or the same kind chosen as a preset.
  defp replaced?(path, key, kind, new) do
    new[key] != path or new["background_type"] != kind or new["background_value"] != "custom"
  end
end
