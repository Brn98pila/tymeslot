defmodule TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomizationComponent do
  @moduledoc """
  Theme customization component for advanced theme settings.
  Allows users to customize colors and backgrounds for their booking page.

  Assigns contract
  - Required (passed in):
    - profile: Tymeslot.Profiles.ProfileSchema.t()
    - theme_id: String.t()
  - Provided/managed by this component (do not pass these in):
    - customization: map with current customization state (see customization_t())
    - presets: preset collections for color schemes and backgrounds (see presets_t())
    - option_groups: the theme spec's option groups, one panel each (`ThemeCustomizations.option_groups/1`)
    - browsing_type: String.t() – which background category is currently browsed (one of the background group's kinds)
    - uploads: map() – upload entries, present only when the spec declares asset fields
    - parent_component: term() – reference to parent component for close actions (optional)
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  require Logger

  alias Phoenix.LiveView.Socket
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.ThemeCustomizations
  alias Tymeslot.ThemeCustomizations.Options.Background
  alias Tymeslot.ThemeCustomizations.Options.Palette
  alias Tymeslot.Themes.Catalog
  alias TymeslotWeb.Dashboard.ThemeSettings.BackgroundUploads
  alias TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.Components
  alias TymeslotWeb.Live.Shared.Flash

  @typedoc "Preset collections used by the component"
  @type presets_t :: %{
          required(:color_schemes) => %{optional(String.t()) => map()},
          required(:gradients) => %{
            optional(String.t()) => %{
              required(:name) => String.t(),
              required(:value) => String.t()
            }
          },
          required(:images) => %{
            optional(String.t()) => %{
              required(:name) => String.t(),
              required(:file) => String.t(),
              optional(:description) => String.t()
            }
          },
          required(:videos) => %{
            optional(String.t()) => %{
              required(:name) => String.t(),
              required(:file) => String.t(),
              required(:thumbnail) => String.t(),
              optional(:description) => String.t()
            }
          }
        }

  @typedoc "Customization applied to the theme"
  @type customization_t :: Tymeslot.ThemeCustomizations.ThemeCustomizationSchema.t()

  @typedoc "Assigns contract for this component"
  @type assigns_t :: %{
          required(:profile) => Tymeslot.Profiles.ProfileSchema.t(),
          required(:theme_id) => String.t(),
          required(:customization) => customization_t(),
          required(:presets) => presets_t(),
          required(:option_groups) => [map()],
          required(:browsing_type) => String.t() | nil,
          optional(:uploads) => map() | nil,
          optional(:parent_component) => term()
        }

  @impl Phoenix.LiveComponent
  @spec mount(Socket.t()) :: {:ok, Socket.t()}
  def mount(socket), do: {:ok, socket}

  @impl Phoenix.LiveComponent
  @spec update(map(), Socket.t()) :: {:ok, Socket.t()}
  def update(%{consume_upload: type}, socket) do
    # Handle async consumption from progress handlers
    {:noreply, socket} =
      case type do
        :image -> handle_event("save_background_image", %{}, socket)
        :video -> handle_event("save_background_video", %{}, socket)
      end

    {:ok, socket}
  end

  def update(assigns, socket) do
    theme_id = assigns[:theme_id] || Catalog.default_id()

    %{customization: customization, presets: presets} =
      ThemeCustomizations.initialize_customization(assigns.profile.id, theme_id)

    option_groups = ThemeCustomizations.option_groups(theme_id)

    {:ok,
     socket
     |> assign(
       id: assigns.id,
       profile: assigns.profile,
       parent_component: assigns[:parent_component],
       theme_id: theme_id,
       customization: customization,
       presets: presets,
       option_groups: option_groups
     )
     |> BackgroundUploads.configure(__MODULE__, ThemeCustomizations.asset_fields(theme_id))
     |> assign_new(:browsing_type, fn -> initial_browsing_type(customization, option_groups) end)
     |> assign_new(:custom_picker_open, fn -> false end)
     |> assign_new(:palette_picker_open, fn ->
       not is_nil(customization.settings["custom_palette_seed"])
     end)}
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div class="space-y-8" phx-hook="AutoUpload" id="theme-customization-uploads">
      <.section_header level={3} title={dgettext("dashboard_appearance", "Theme Customization")} />
      <Components.toolbar
        profile={@profile}
        theme_id={@theme_id}
        parent_component={@parent_component}
      />

      <Components.option_panel
        :for={group <- @option_groups}
        group={group}
        customization={@customization}
        presets={@presets}
        uploads={assigns[:uploads]}
        myself={@myself}
        browsing_type={@browsing_type}
        palette_picker_open={@palette_picker_open}
        custom_picker_open={@custom_picker_open}
      />
    </div>
    """
  end

  @impl Phoenix.LiveComponent
  @spec handle_event(String.t(), map(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_event(
        "theme:set_option",
        %{"option" => option, "field" => field, "choice" => choice},
        socket
      )
      when is_binary(option) and is_binary(field) and is_binary(choice) do
    case Enum.find(socket.assigns.option_groups, &(Atom.to_string(&1.key) == option)) do
      nil -> {:noreply, socket}
      group -> set_option(socket, group, field, choice)
    end
  end

  def handle_event("theme:set_option", _params, socket), do: {:noreply, socket}

  def handle_event("theme:toggle_palette_picker", _params, socket) do
    if is_nil(socket.assigns.customization.settings["custom_palette_seed"]) do
      with_rate_limit(socket, "color_scheme", fn ->
        case ThemeCustomizations.apply_option(
               socket.assigns.profile.id,
               socket.assigns.theme_id,
               :palette,
               %{"field" => "seed", "value" => ThemeCustomizations.default_custom_palette_seed()}
             ) do
          {:ok, updated} ->
            emit_telemetry(:palette_seed_set, socket, %{
              seed: updated.settings["custom_palette_seed"]
            })

            {:noreply,
             socket
             |> assign(:customization, updated)
             |> assign(:palette_picker_open, true)}

          {:error, reason} ->
            Flash.error(reason)
            {:noreply, socket}
        end
      end)
    else
      {:noreply, update(socket, :palette_picker_open, &(!&1))}
    end
  end

  def handle_event("theme:set_browsing_type", %{"type" => type}, socket) do
    # UI navigation only, not a selection
    if type in background_kinds(socket.assigns.option_groups) do
      {:noreply, assign(socket, :browsing_type, type)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("theme:toggle_custom_picker", _params, socket) do
    {:noreply, update(socket, :custom_picker_open, &(!&1))}
  end

  def handle_event("validate_image", _params, socket) do
    {:noreply, consume_upload_and_notify(socket, :image)}
  end

  def handle_event("save_background_image", _params, socket) do
    {:noreply, consume_upload_and_notify(socket, :image)}
  end

  def handle_event("validate_video", _params, socket) do
    {:noreply, consume_upload_and_notify(socket, :video)}
  end

  def handle_event("save_background_video", _params, socket) do
    {:noreply, consume_upload_and_notify(socket, :video)}
  end

  # Private functions

  defp set_option(socket, group, field, value) do
    {event, action, metadata} = telemetry_for(group, field, value)

    with_rate_limit(socket, action, fn ->
      case ThemeCustomizations.apply_option(
             socket.assigns.profile.id,
             socket.assigns.theme_id,
             group.key,
             %{"field" => field, "value" => value}
           ) do
        {:ok, updated} ->
          emit_telemetry(event, socket, metadata)

          {:noreply,
           socket
           |> assign(:customization, updated)
           |> after_option_set(group, field, updated)}

        {:error, reason} ->
          Flash.error(reason)
          {:noreply, socket}
      end
    end)
  end

  defp after_option_set(socket, %{module: Palette}, _field, updated),
    do: assign(socket, :palette_picker_open, not is_nil(updated.settings["custom_palette_seed"]))

  defp after_option_set(socket, %{module: Background}, kind, _updated),
    do: assign(socket, :browsing_type, kind)

  defp after_option_set(socket, _group, _field, _updated), do: socket

  # Event names and rate-limit labels as they were before the single event.
  defp telemetry_for(%{module: Palette}, "seed", value),
    do: {:palette_seed_changed, "palette_seed", %{seed: value}}

  defp telemetry_for(%{module: Palette}, _field, value),
    do: {:color_scheme_changed, "color_scheme", %{scheme_id: value}}

  defp telemetry_for(%{module: Background}, kind, value),
    do: {:background_changed, "background", %{type: kind, value: value}}

  defp telemetry_for(group, field, value),
    do: {:option_changed, Atom.to_string(group.key), %{field: field, value: value}}

  defp background_kinds(option_groups) do
    case Enum.find(option_groups, &(&1.module == Background)) do
      %{kinds: kinds} -> Enum.map(kinds, &Atom.to_string/1)
      nil -> []
    end
  end

  defp initial_browsing_type(customization, option_groups) do
    kinds = background_kinds(option_groups)

    if customization.settings["background_type"] in kinds,
      do: customization.settings["background_type"],
      else: List.first(kinds)
  end

  # `AutoUpload` (mounted at the root of this component's markup, see
  # `render/1`) only clears the file picker once it receives "upload-complete",
  # so re-selecting the same background file after a successful upload needs
  # this pushed explicitly. `BackgroundUploads.consume/2` doesn't report
  # success directly, so success is inferred from the stored path changing;
  # a no-op (not ready yet, rate-limited, or a validation error) leaves the
  # path untouched and pushes nothing.
  defp consume_upload_and_notify(socket, kind) do
    path_before = background_path(socket.assigns.customization, kind)
    socket = BackgroundUploads.consume(socket, kind)
    path_after = background_path(socket.assigns.customization, kind)

    if path_after != path_before do
      push_event(socket, "upload-complete", %{})
    else
      socket
    end
  end

  defp background_path(customization, :image), do: customization.settings["background_image_path"]
  defp background_path(customization, :video), do: customization.settings["background_video_path"]

  # Rate limiting helper that validates user_id and checks rate limit before executing operation
  @spec with_rate_limit(Socket.t(), String.t(), (-> {:noreply, Socket.t()})) ::
          {:noreply, Socket.t()}
  defp with_rate_limit(socket, action, operation) do
    user_id = socket.assigns.profile.user_id
    profile_id = socket.assigns.profile.id

    # Validate user_id before proceeding
    if is_nil(user_id) or not is_integer(user_id) or user_id <= 0 do
      Logger.error("Invalid user_id in theme customization",
        user_id: LogFormat.reason(user_id),
        profile_id: profile_id
      )

      Flash.error(
        dgettext(
          "dashboard_appearance",
          "An error occurred. Please refresh the page and try again."
        )
      )

      {:noreply, socket}
    else
      case RateLimiter.check_theme_customization_rate_limit(user_id) do
        :ok ->
          operation.()

        {:error, :rate_limited, message} ->
          emit_telemetry(:rate_limited, socket, %{action: action})
          Flash.error(message)
          {:noreply, socket}

        {:error, :invalid_user_id} ->
          Logger.error("Rate limiter rejected invalid user_id",
            user_id: LogFormat.reason(user_id),
            profile_id: profile_id
          )

          Flash.error(
            dgettext(
              "dashboard_appearance",
              "An error occurred. Please refresh the page and try again."
            )
          )

          {:noreply, socket}
      end
    end
  end

  # Emit telemetry events for monitoring and metrics
  # SECURITY: Telemetry handlers must be properly secured as these events include user_id and profile_id
  @spec emit_telemetry(atom(), Socket.t(), map()) :: :ok
  defp emit_telemetry(event_name, socket, metadata) do
    :telemetry.execute(
      [:tymeslot, :theme_customization, event_name],
      %{count: 1},
      Map.merge(
        %{
          user_id: socket.assigns.profile.user_id,
          profile_id: socket.assigns.profile.id,
          theme_id: socket.assigns.theme_id
        },
        metadata
      )
    )
  end
end
