defmodule Tymeslot.ThemeCustomizations.ThemeCustomizationSchema do
  @moduledoc """
  Schema for user theme customizations including color schemes and backgrounds.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Tymeslot.Profiles.ProfileSchema
  alias Tymeslot.ThemeCustomizations.Presets
  alias Tymeslot.Themes.Catalog

  @type t :: %__MODULE__{
          id: integer() | nil,
          profile_id: integer() | nil,
          theme_id: String.t() | nil,
          color_scheme: String.t(),
          custom_palette_seed: String.t() | nil,
          background_type: String.t(),
          background_value: String.t() | nil,
          background_image_path: String.t() | nil,
          background_video_path: String.t() | nil,
          video_processing: String.t() | nil,
          profile: ProfileSchema.t() | Ecto.Association.NotLoaded.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @valid_color_schemes ~w[default turquoise purple sunset ocean forest rose monochrome]
  @hex_color_regex ~r/^#[0-9A-Fa-f]{6}$/
  @valid_background_types ~w[gradient color image video]
  @valid_video_processing_states ~w[pending completed failed]

  schema "theme_customizations" do
    field(:theme_id, :string)
    field(:color_scheme, :string, default: "default")
    field(:custom_palette_seed, :string)
    field(:background_type, :string, default: "gradient")
    field(:background_value, :string)
    field(:background_image_path, :string)
    field(:background_video_path, :string)
    field(:video_processing, :string)

    belongs_to(:profile, ProfileSchema, foreign_key: :profile_id)

    timestamps(type: :utc_datetime)
  end

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(theme_customization, attrs) do
    theme_customization
    |> cast(attrs, [
      :profile_id,
      :theme_id,
      :color_scheme,
      :custom_palette_seed,
      :background_type,
      :background_value,
      :background_image_path,
      :background_video_path,
      :video_processing
    ])
    |> validate_required([:profile_id, :theme_id, :background_type])
    |> validate_theme_id()
    |> validate_color_scheme_or_seed()
    |> validate_inclusion(:background_type, @valid_background_types)
    |> validate_inclusion(:video_processing, @valid_video_processing_states)
    |> validate_background_value()
    |> validate_custom_palette_seed()
    |> foreign_key_constraint(:profile_id)
    |> unique_constraint([:profile_id, :theme_id])
  end

  defp validate_background_value(changeset) do
    background_type = get_field(changeset, :background_type)

    case background_type do
      "gradient" -> validate_gradient(changeset)
      "color" -> validate_color(changeset)
      "image" -> validate_image(changeset)
      "video" -> validate_video(changeset)
      _other -> changeset
    end
  end

  defp validate_gradient(changeset) do
    background_value = get_field(changeset, :background_value)

    if background_value && Map.has_key?(Presets.get_gradient_presets(), background_value) do
      changeset
    else
      add_error(changeset, :background_value, "must be a valid gradient preset")
    end
  end

  defp validate_color(changeset) do
    background_value = get_field(changeset, :background_value)

    if background_value && String.match?(background_value, @hex_color_regex) do
      changeset
    else
      add_error(changeset, :background_value, "must be a valid hex color")
    end
  end

  # When a custom palette seed is present it is the source of truth for the
  # colour scheme; `color_scheme` is not constrained.  When no seed is present,
  # `color_scheme` must be a known preset.
  defp validate_color_scheme_or_seed(changeset) do
    seed = get_field(changeset, :custom_palette_seed)

    if is_binary(seed) and seed != "" do
      changeset
    else
      changeset
      |> validate_required([:color_scheme])
      |> validate_inclusion(:color_scheme, @valid_color_schemes)
    end
  end

  defp validate_custom_palette_seed(changeset) do
    seed = get_field(changeset, :custom_palette_seed)

    if is_nil(seed) or seed == "" do
      changeset
    else
      if String.match?(seed, @hex_color_regex) do
        changeset
      else
        add_error(changeset, :custom_palette_seed, "must be a valid hex colour")
      end
    end
  end

  defp validate_image(changeset) do
    background_value = get_field(changeset, :background_value)

    # Preset images don't need an image path
    if background_value && String.starts_with?(background_value, "preset:") do
      changeset
    else
      # Uploaded images require an image path
      if get_field(changeset, :background_image_path) do
        changeset
      else
        add_error(changeset, :background_image_path, "is required for uploaded image background")
      end
    end
  end

  defp validate_video(changeset) do
    background_value = get_field(changeset, :background_value)

    # Preset videos don't need a video path
    if background_value && String.starts_with?(background_value, "preset:") do
      changeset
    else
      # Uploaded videos require a video path
      if get_field(changeset, :background_video_path) do
        changeset
      else
        add_error(changeset, :background_video_path, "is required for uploaded video background")
      end
    end
  end

  defp validate_theme_id(changeset) do
    case get_field(changeset, :theme_id) do
      nil ->
        changeset

      theme_id ->
        if Catalog.valid_id?(theme_id) do
          changeset
        else
          add_error(changeset, :theme_id, "is not a valid theme")
        end
    end
  end
end
