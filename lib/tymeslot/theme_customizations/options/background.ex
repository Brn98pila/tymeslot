defmodule Tymeslot.ThemeCustomizations.Options.Background do
  @moduledoc """
  The background option: a gradient preset, a solid colour, a preset or
  uploaded image, or a preset or uploaded video. Stored in the `background_*`
  columns.

  A spec passes the kinds its theme offers to `changeset/3`, which rejects the
  rest, so no write path can store a background the theme cannot show. A
  `preset:` value must name a shipped preset; any other image or video value is
  an upload and needs its stored path.
  """

  import Ecto.Changeset

  alias Ecto.Changeset
  alias Tymeslot.ThemeCustomizations.Presets
  alias Tymeslot.ThemeCustomizations.Spec
  alias Tymeslot.ThemeCustomizations.Tokens
  alias Tymeslot.ThemeCustomizations.Validation
  alias Tymeslot.Utils.Colour

  @fields [:background_type, :background_value, :background_image_path, :background_video_path]
  @kinds_by_type %{
    "gradient" => :gradient,
    "color" => :color,
    "image" => :image,
    "video" => :video
  }

  @doc "Casts and validates the background settings against the kinds the theme offers."
  @spec changeset(Changeset.t(), map(), [Spec.background_kind()]) :: Changeset.t()
  def changeset(changeset, attrs, kinds) do
    changeset
    |> cast(attrs, @fields)
    |> validate_required([:background_type])
    |> validate_inclusion(:background_type, Map.keys(@kinds_by_type))
    |> validate_supported(kinds)
    |> validate_value()
  end

  @doc "The upload columns and what each stores."
  @spec asset_fields() :: [{atom(), Spec.asset_kind()}]
  def asset_fields, do: [background_image_path: :image, background_video_path: :video]

  @doc "The background's CSS variables. Videos render as markup, so they emit none."
  @spec vars(Spec.settings()) :: Tokens.css_vars()
  def vars(%{"background_type" => "gradient", "background_value" => id}) do
    case Presets.find_preset_by_id(:gradient, id) do
      %{value: gradient} -> %{"--theme-background" => gradient}
      nil -> %{}
    end
  end

  def vars(%{"background_type" => "color", "background_value" => value}) do
    case Colour.cast_hex(value) do
      {:ok, hex} -> %{"--theme-background" => hex}
      :error -> %{}
    end
  end

  def vars(%{"background_type" => "image"} = settings) do
    path = settings["background_image_path"]

    cond do
      is_binary(path) ->
        %{"--theme-background-image" => "url('/uploads/#{Validation.sanitize_path(path)}')"}

      preset = Presets.find_preset_by_id(:image, settings["background_value"]) ->
        %{"--theme-background-image" => "url('/images/ui/backgrounds/#{preset.file}')"}

      true ->
        %{}
    end
  end

  def vars(_settings), do: %{}

  defp validate_supported(changeset, kinds) do
    kind = Map.get(@kinds_by_type, get_field(changeset, :background_type))

    if kind && kind not in kinds do
      add_error(changeset, :background_type, "is not supported by this theme")
    else
      changeset
    end
  end

  defp validate_value(changeset) do
    case get_field(changeset, :background_type) do
      "gradient" ->
        validate_preset(
          changeset,
          Presets.get_gradient_presets(),
          "must be a valid gradient preset"
        )

      "color" ->
        cast_colour(changeset)

      "image" ->
        validate_media(changeset, Presets.get_image_presets(), :background_image_path, "image")

      "video" ->
        validate_media(changeset, Presets.get_video_presets(), :background_video_path, "video")

      _invalid_type ->
        changeset
    end
  end

  defp validate_preset(changeset, presets, message) do
    if Map.has_key?(presets, get_field(changeset, :background_value)),
      do: changeset,
      else: add_error(changeset, :background_value, message)
  end

  defp cast_colour(changeset) do
    case Colour.cast_hex(get_field(changeset, :background_value)) do
      {:ok, hex} -> put_change(changeset, :background_value, hex)
      :error -> add_error(changeset, :background_value, "must be a valid hex color")
    end
  end

  defp validate_media(changeset, presets, path_field, label) do
    value = get_field(changeset, :background_value)

    cond do
      is_binary(value) and String.starts_with?(value, "preset:") ->
        validate_preset(changeset, presets, "must be a valid #{label} preset")

      get_field(changeset, path_field) ->
        changeset

      true ->
        add_error(changeset, path_field, "is required for uploaded #{label} background")
    end
  end
end
