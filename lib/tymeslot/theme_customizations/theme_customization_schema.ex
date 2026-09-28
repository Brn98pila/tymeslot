defmodule Tymeslot.ThemeCustomizations.ThemeCustomizationSchema do
  @moduledoc """
  Schema for user theme customizations including color schemes and backgrounds.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Tymeslot.Profiles.ProfileSchema
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

  @doc """
  Casts the shared columns and hands the theme's own settings to its
  customisation spec, which validates them (including whether the theme
  supports the option at all).
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(theme_customization, attrs) do
    theme_customization
    |> cast(attrs, [:profile_id, :theme_id, :video_processing])
    |> validate_required([:profile_id, :theme_id])
    |> validate_inclusion(:video_processing, @valid_video_processing_states)
    |> apply_theme_spec(attrs)
    |> foreign_key_constraint(:profile_id)
    |> unique_constraint([:profile_id, :theme_id])
  end

  defp apply_theme_spec(changeset, attrs) do
    case get_field(changeset, :theme_id) do
      nil ->
        changeset

      theme_id ->
        case Catalog.customization_spec(theme_id) do
          {:ok, spec} -> spec.changeset(changeset, attrs)
          {:error, :theme_not_found} -> add_error(changeset, :theme_id, "is not a valid theme")
        end
    end
  end
end
