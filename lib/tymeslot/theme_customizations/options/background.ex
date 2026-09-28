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
  alias Tymeslot.Media.Transcoder
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

  @preset_image_dir "/images/themes/backgrounds/"
  @preset_video_dir "/videos/backgrounds/"
  @poster_dir "/images/ui/posters/"
  @preset_video_variants [
    {"-desktop.webm", "video/webm", "(min-width: 1024px)"},
    {"-desktop.mp4", "video/mp4", "(min-width: 1024px)"},
    {"-mobile.mp4", "video/mp4", "(max-width: 768px)"},
    {"-low.mp4", "video/mp4", "(max-width: 480px)"},
    {"-original.mp4", "video/mp4", nil}
  ]

  @typedoc "One `<source>` of a background video, in the order the browser should try them."
  @type video_source :: %{src: String.t(), type: String.t(), media: String.t() | nil}

  @typedoc "A resolved, render-ready background. Every path in it is already safe to emit."
  @type descriptor ::
          %{kind: :gradient, css: String.t()}
          | %{kind: :color, color: String.t()}
          | %{kind: :image, url: String.t()}
          | %{kind: :video, sources: [video_source()], poster: String.t() | nil}

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

  @doc """
  The changes choosing a background makes. An upload survives only when the
  new background is that same kind chosen as `"custom"`; every other choice
  (a preset of either kind, a gradient, or a colour) drops both uploads, so a
  stored file is never orphaned by a change that stops naming it.
  """
  @spec changes(String.t(), String.t()) :: {:ok, map()}
  def changes(kind, value) do
    {:ok,
     Map.merge(
       %{"background_type" => kind, "background_value" => value},
       cleared_uploads(kind, value)
     )}
  end

  @doc """
  Resolves the stored background into a descriptor the theme wrapper renders.

  Every path in it is already safe to emit. Returns `nil` when the settings
  name nothing that resolves (an unknown preset, an image kind with neither
  upload nor preset); the wrapper then falls back to the theme's own
  background.
  """
  @spec descriptor(Spec.settings()) :: descriptor() | nil
  def descriptor(%{"background_type" => "gradient", "background_value" => id}) do
    case Presets.find_preset_by_id(:gradient, id) do
      %{value: css} -> %{kind: :gradient, css: css}
      nil -> nil
    end
  end

  def descriptor(%{"background_type" => "color", "background_value" => value}) do
    case Colour.cast_hex(value) do
      {:ok, hex} -> %{kind: :color, color: hex}
      :error -> nil
    end
  end

  def descriptor(%{"background_type" => "image", "background_image_path" => path})
      when is_binary(path) and path != "" do
    %{kind: :image, url: "/uploads/" <> Validation.sanitize_path(path)}
  end

  def descriptor(%{"background_type" => "image"} = settings) do
    case Presets.find_preset_by_id(:image, settings["background_value"]) do
      %{file: file} -> %{kind: :image, url: preset_image_url(file)}
      nil -> nil
    end
  end

  def descriptor(%{"background_type" => "video"} = settings) do
    %{
      kind: :video,
      sources: video_sources(settings),
      poster: poster(settings["background_value"])
    }
  end

  def descriptor(_settings), do: nil

  @doc """
  The public URL of a preset image file, as booking pages and the dashboard
  picker both load it.
  """
  @spec preset_image_url(String.t()) :: String.t()
  def preset_image_url(file) when is_binary(file), do: @preset_image_dir <> file

  @doc """
  The `--theme-background` custom property for a descriptor.

  Gradients and colours are the background itself. Behind an image or a video
  (or when nothing resolved) the page shows the palette's canvas colour, as it
  always has; with no palette either, the theme's own default stands.
  """
  @spec vars(descriptor() | nil, Tokens.css_vars()) :: Tokens.css_vars()
  def vars(%{kind: :gradient, css: css}, _palette_vars), do: %{"--theme-background" => css}
  def vars(%{kind: :color, color: hex}, _palette_vars), do: %{"--theme-background" => hex}

  def vars(_media_or_nil, %{"--theme-canvas" => _canvas}),
    do: %{"--theme-background" => "var(--theme-canvas)"}

  def vars(_media_or_nil, _palette_vars), do: %{}

  defp cleared_uploads("image", "custom"), do: %{"background_video_path" => nil}
  defp cleared_uploads("video", "custom"), do: %{"background_image_path" => nil}

  defp cleared_uploads(_kind, _value),
    do: %{"background_image_path" => nil, "background_video_path" => nil}

  defp video_sources(%{"background_video_path" => path}) when is_binary(path) and path != "" do
    sanitized = Validation.sanitize_path(path)
    base = Path.rootname(sanitized)

    variants =
      Enum.map(Transcoder.variant_definitions(), fn variant ->
        %{src: "/uploads/" <> base <> variant.suffix, type: variant.type, media: variant.media}
      end)

    # The original upload is always the last fallback.
    variants ++ [%{src: "/uploads/" <> sanitized, type: "video/mp4", media: nil}]
  end

  defp video_sources(settings) do
    case Presets.find_preset_by_id(:video, settings["background_value"]) do
      %{file: file} -> preset_sources(file)
      nil -> []
    end
  end

  # A preset ships five sizes, tried in this order; the original is the last
  # fallback.
  defp preset_sources(desktop_file) do
    base =
      desktop_file
      |> String.replace("-desktop.mp4", "")
      |> String.replace("-desktop.webm", "")

    Enum.map(@preset_video_variants, fn {suffix, type, media} ->
      %{src: @preset_video_dir <> base <> suffix, type: type, media: media}
    end)
  end

  defp poster(value) do
    case Presets.find_preset_by_id(:video, value) do
      %{poster: poster} when is_binary(poster) -> @poster_dir <> poster
      _other -> nil
    end
  end

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
