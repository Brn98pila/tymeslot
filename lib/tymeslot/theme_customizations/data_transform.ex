defmodule Tymeslot.ThemeCustomizations.DataTransform do
  @moduledoc """
  Normalises a customisation (schema struct, atom- or string-keyed map) to the
  string-keyed settings map that specs, tokens and saves work on, so no caller
  reads `m[:k] || m["k"]`.
  """

  alias Tymeslot.ThemeCustomizations.Spec
  alias Tymeslot.ThemeCustomizations.ThemeCustomizationSchema

  @setting_keys ~w(color_scheme custom_palette_seed background_type background_value background_image_path background_video_path)

  @spec to_settings(ThemeCustomizationSchema.t() | map() | nil) :: Spec.settings()
  def to_settings(nil), do: %{}

  def to_settings(%ThemeCustomizationSchema{} = customization),
    do: customization |> Map.from_struct() |> to_settings()

  def to_settings(customization) when is_map(customization) do
    customization
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> Map.take(@setting_keys)
  end
end
