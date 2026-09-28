defmodule Tymeslot.ThemeCustomizations do
  @moduledoc """
  The ThemeCustomizations context for managing user theme customizations.
  Main orchestrator that coordinates between functional submodules and handles I/O operations.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Ecto.Changeset
  alias Tymeslot.Profiles.ProfileSchema
  alias Tymeslot.ThemeCustomizations.Options.Palette
  alias Tymeslot.ThemeCustomizations.Spec
  alias Tymeslot.ThemeCustomizations.ThemeCustomizationQueries
  alias Tymeslot.ThemeCustomizations.ThemeCustomizationSchema
  alias Tymeslot.ThemeCustomizations.Tokens
  alias Tymeslot.Themes.Catalog

  # Functional submodules
  alias __MODULE__.{
    Assets,
    Backgrounds,
    Css,
    DataTransform,
    FileLifecycle,
    Presets,
    Storage
  }

  @type profile_id :: pos_integer()
  @type theme_id :: String.t()
  @type user_id :: pos_integer()
  @type customization_input :: ThemeCustomizationSchema.t() | map() | nil
  @type upload_attrs :: %{path: String.t(), filename: String.t()}
  @type persistence_result :: {:ok, ThemeCustomizationSchema.t()} | {:error, Changeset.t()}

  @doc """
  Gets a theme customization by profile ID and theme ID.
  """
  @spec get_by_profile_and_theme(profile_id(), theme_id()) ::
          ThemeCustomizationSchema.t() | nil
  def get_by_profile_and_theme(profile_id, theme_id) do
    ThemeCustomizationQueries.get_by_profile_and_theme(profile_id, theme_id)
  end

  @doc """
  Returns a random video-background preset key (e.g. `"preset:blue-wave"`).

  Used to seed a fresh account with a moving background so its booking page —
  and the onboarding preview of it — has life out of the box.
  """
  @spec random_video_preset() :: String.t()
  def random_video_preset, do: Enum.random(video_preset_keys())

  @doc """
  The shipped video-background preset keys (e.g. `"preset:blue-wave"`), sorted.
  """
  @spec video_preset_keys() :: [String.t()]
  def video_preset_keys, do: Presets.get_video_presets() |> Map.keys() |> Enum.sort()

  @doc """
  Whether a theme can show the given kind of background. `false` for an
  unknown theme.
  """
  @spec supports_background?(theme_id(), Spec.background_kind()) :: boolean()
  def supports_background?(theme_id, kind) do
    case Catalog.customization_spec(theme_id) do
      {:ok, spec} -> Spec.supports_background?(spec, kind)
      {:error, :theme_not_found} -> false
    end
  end

  @doc """
  Stores an uploaded file for one of the theme's asset fields and saves it on
  the profile's customisation. See `Tymeslot.ThemeCustomizations.Assets`.
  """
  @spec attach_asset(profile_id(), theme_id(), atom(), upload_attrs()) ::
          {:ok, ThemeCustomizationSchema.t()} | {:error, String.t()}
  defdelegate attach_asset(profile_id, theme_id, field, upload), to: Assets

  @doc "The upload columns the theme's customisation spec declares, with the kind of each."
  @spec asset_fields(theme_id()) :: [{atom(), Spec.asset_kind()}]
  def asset_fields(theme_id), do: Spec.for_theme(theme_id).asset_fields()

  @doc """
  Creates or updates a theme customization for a profile and theme.
  """
  @spec upsert_theme_customization(profile_id(), theme_id(), map()) ::
          persistence_result()
  def upsert_theme_customization(profile_id, theme_id, attrs) do
    case get_by_profile_and_theme(profile_id, theme_id) do
      nil ->
        create_theme_customization(profile_id, theme_id, Map.merge(get_defaults(theme_id), attrs))

      customization ->
        # Update only the provided fields
        update_theme_customization(customization, attrs)
    end
  end

  @doc """
  Creates a theme customization for a profile and theme.
  """
  @spec create_theme_customization(profile_id(), theme_id(), map()) :: persistence_result()
  def create_theme_customization(profile_id, theme_id, attrs) do
    attrs =
      attrs
      |> Map.put("profile_id", profile_id)
      |> Map.put("theme_id", theme_id)

    # Create the customization with race condition handling
    case ThemeCustomizationQueries.create(attrs) do
      {:ok, result} ->
        {:ok, result}

      {:error, changeset} ->
        # If we hit a unique constraint, it means another request created it concurrently.
        # In this case, we should update the existing record instead.
        if has_unique_constraint_error?(changeset) do
          case get_by_profile_and_theme(profile_id, theme_id) do
            # Should not happen if constraint violated
            nil -> {:error, changeset}
            customization -> update_theme_customization(customization, attrs)
          end
        else
          {:error, changeset}
        end
    end
  end

  defp has_unique_constraint_error?(changeset) do
    Enum.any?(changeset.errors, fn {field, {_msg, opts}} ->
      field == :profile_id and Keyword.get(opts, :constraint) == :unique
    end)
  end

  @doc """
  Updates a theme customization using the unified upload system.
  """
  @spec update_theme_customization(ThemeCustomizationSchema.t(), map()) ::
          persistence_result()
  def update_theme_customization(%ThemeCustomizationSchema{} = customization, attrs) do
    # Perform the atomic database update, then cleanup replaced files on success
    case ThemeCustomizationQueries.update(customization, attrs) do
      {:ok, updated} ->
        FileLifecycle.cleanup_replaced_files(customization, updated)
        {:ok, updated}

      error ->
        error
    end
  end

  @doc """
  Removes every theme background file stored for a deleted profile. The rows
  are expected to be gone already; this touches the filesystem only.
  """
  @spec delete_profile_files(profile_id()) :: :ok | {:error, File.posix(), Path.t()}
  def delete_profile_files(profile_id), do: Storage.delete_profile_directory(profile_id)

  @doc """
  Deletes a theme customization.
  """
  @spec delete_theme_customization(ThemeCustomizationSchema.t()) ::
          {:ok, ThemeCustomizationSchema.t()} | {:error, Changeset.t()}
  def delete_theme_customization(%ThemeCustomizationSchema{} = customization) do
    # Delete database record first, then cleanup files on success
    case ThemeCustomizationQueries.delete(customization) do
      {:ok, deleted} ->
        FileLifecycle.cleanup_all_files(customization)
        {:ok, deleted}

      error ->
        error
    end
  end

  @doc """
  The stored settings of a customisation as a string-keyed map, the shape specs
  and tokens work on. Empty for `nil`.
  """
  @spec to_map(customization_input()) :: map()
  def to_map(customization) do
    DataTransform.to_settings(customization)
  end

  @doc """
  The theme's customisation defaults as string-keyed attrs, from its spec.
  """
  @spec get_defaults(theme_id()) :: map()
  def get_defaults(theme_id) do
    Map.new(Spec.for_theme(theme_id).defaults(), fn {key, value} ->
      {Atom.to_string(key), value}
    end)
  end

  @doc """
  An unsaved customisation holding the theme's defaults, for a profile that has
  not customised the theme (or `nil` for a preview without one).
  """
  @spec default_customization(profile_id() | nil, theme_id()) :: ThemeCustomizationSchema.t()
  def default_customization(profile_id, theme_id) do
    struct(
      ThemeCustomizationSchema,
      Map.merge(Spec.for_theme(theme_id).defaults(), %{profile_id: profile_id, theme_id: theme_id})
    )
  end

  @doc """
  The render tokens for a theme: the saved settings (or the theme's defaults
  when nothing is saved) plus any per-request overrides, through the theme's
  customisation spec.
  """
  @spec tokens(theme_id(), ThemeCustomizationSchema.t() | nil, Palette.overrides()) ::
          Tokens.t()
  def tokens(theme_id, customization, overrides \\ %{}) do
    settings = customization || default_customization(nil, theme_id)
    Spec.for_theme(theme_id).tokens(to_map(settings), overrides)
  end

  # New orchestrator functions for component interface

  @doc """
  Initializes customization data for the component.
  Returns all data needed for component initialization.
  """
  @spec initialize_customization(profile_id(), theme_id()) :: %{
          customization: ThemeCustomizationSchema.t(),
          original: ThemeCustomizationSchema.t(),
          presets: map()
        }
  def initialize_customization(profile_id, theme_id) do
    saved = get_by_profile_and_theme(profile_id, theme_id)
    customization = saved || default_customization(profile_id, theme_id)

    %{
      customization: customization,
      original: saved || customization,
      presets: Presets.get_all_presets()
    }
  end

  @default_custom_palette_seed "#06b6d4"

  @doc """
  Returns the brand default seed hex used when a user first activates the
  custom-palette mode and has no previously stored seed.
  """
  @spec default_custom_palette_seed() :: String.t()
  def default_custom_palette_seed, do: @default_custom_palette_seed

  @doc """
  Resolves the active colour scheme for a customization, returning the same
  `%{name, colors}` shape used by both presets and palette derivation.

  When `custom_palette_seed` is present on the customization, the palette is
  derived from that seed; otherwise the `color_scheme` field is looked up in
  the provided `presets.color_schemes` map.  Returns `nil` if neither resolves
  to a known scheme.
  """
  @spec resolve_active_scheme(ThemeCustomizationSchema.t() | map(), map()) :: map() | nil
  defdelegate resolve_active_scheme(customization, presets), to: Css

  @doc """
  Applies a color scheme change through the component interface.

  Switching to the "custom" scheme reuses the existing seed if one is already
  stored; otherwise it seeds with the brand turquoise default. Use
  `apply_custom_palette_change/4` directly when the user picks a specific
  custom seed.
  """
  @spec apply_color_scheme_change(
          profile_id(),
          theme_id(),
          ThemeCustomizationSchema.t() | map(),
          String.t() | atom()
        ) :: {:ok, ThemeCustomizationSchema.t()} | {:error, String.t()}
  def apply_color_scheme_change(profile_id, theme_id, current_customization, "custom") do
    seed = Css.get_seed(current_customization) || @default_custom_palette_seed
    apply_custom_palette_change(profile_id, theme_id, current_customization, seed)
  end

  def apply_color_scheme_change(profile_id, theme_id, current_customization, scheme_id) do
    attrs =
      Map.merge(DataTransform.to_settings(current_customization), %{
        "color_scheme" => scheme_id,
        "custom_palette_seed" => nil
      })

    profile_id
    |> upsert_theme_customization(theme_id, attrs)
    |> format_persistence_error()
  end

  @doc """
  Switches the customisation to the "custom" colour scheme and persists the seed
  hex used to derive the palette.

  The seed must be a `#RGB` or `#RRGGBB` hex colour; it is stored as lower-case
  `#rrggbb`.
  """
  @spec apply_custom_palette_change(
          profile_id(),
          theme_id(),
          ThemeCustomizationSchema.t() | map(),
          String.t()
        ) :: {:ok, ThemeCustomizationSchema.t()} | {:error, String.t()}
  def apply_custom_palette_change(profile_id, theme_id, current_customization, seed_hex)
      when is_binary(seed_hex) and seed_hex != "" do
    attrs =
      Map.merge(DataTransform.to_settings(current_customization), %{
        "custom_palette_seed" => seed_hex
      })

    profile_id
    |> upsert_theme_customization(theme_id, attrs)
    |> format_persistence_error()
  end

  def apply_custom_palette_change(_profile_id, _theme_id, _current_customization, _seed_hex),
    do: format_persistence_error({:error, :invalid_seed})

  @doc """
  Applies a background change through the component interface.
  """
  @spec apply_background_change(
          profile_id(),
          theme_id(),
          ThemeCustomizationSchema.t() | map(),
          String.t(),
          String.t() | nil
        ) :: {:ok, ThemeCustomizationSchema.t()} | {:error, String.t()}
  def apply_background_change(profile_id, theme_id, current_customization, type, value) do
    new_customization = Backgrounds.apply_background_selection(current_customization, type, value)
    cleanup_files = Backgrounds.determine_cleanup_files(current_customization, new_customization)

    with {:ok, saved} <-
           profile_id
           |> upsert_theme_customization(theme_id, DataTransform.to_settings(new_customization))
           |> format_persistence_error() do
      Enum.each(cleanup_files, &FileLifecycle.cleanup_old_backgrounds/1)
      {:ok, saved}
    end
  end

  @doc """
  Gets a theme customization for a user, falling back to defaults.
  """
  @spec get_for_user(user_id(), theme_id()) :: ThemeCustomizationSchema.t() | nil
  def get_for_user(user_id, theme_id) do
    profile = get_profile_by_user_id(user_id)

    case profile do
      nil -> nil
      profile -> get_by_profile_and_theme(profile.id, theme_id)
    end
  end

  # Helper to get profile by user_id
  @spec get_profile_by_user_id(user_id()) :: ProfileSchema.t() | nil
  defp get_profile_by_user_id(user_id) do
    ThemeCustomizationQueries.get_profile_by_user_id(user_id)
  end

  # Private functions

  # Converts a rejected write (an invalid changeset or an invalid seed) into a
  # user-safe string. Callers flash the returned message, and `Flash.error/1`
  # guards on binaries, so a raw changeset would crash the component.
  @spec format_persistence_error({:ok, ThemeCustomizationSchema.t()} | {:error, term()}) ::
          {:ok, ThemeCustomizationSchema.t()} | {:error, String.t()}
  defp format_persistence_error({:ok, _result} = ok), do: ok

  defp format_persistence_error({:error, _reason}),
    do:
      {:error,
       dgettext(
         "dashboard_appearance",
         "Could not save your theme customization. Please try again."
       )}
end
