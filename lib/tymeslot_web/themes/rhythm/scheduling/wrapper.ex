defmodule TymeslotWeb.Themes.Rhythm.Scheduling.Wrapper do
  @moduledoc """
  The Rhythm theme's wrapper: its video, gradient, colour or image background
  and wrapper classes around the shared `ThemeShell`.
  """
  use Phoenix.Component

  alias Tymeslot.Themes.Catalog
  alias TymeslotWeb.Themes.Shared.Components.ThemeShell

  import TymeslotWeb.Components.BackgroundMotionToggle,
    only: [background_motion_toggle: 1]

  import TymeslotWeb.Themes.Shared.Customization.Helpers
  import TymeslotWeb.Themes.Shared.VideoSources, only: [video_sources: 1]

  attr :theme_customization, :map, default: nil
  attr :theme_tokens, :any, default: nil
  attr :locale, :string, default: nil
  attr :current_state, :atom, default: nil
  attr :language_dropdown_open, :boolean, default: nil
  attr :organizer_user_id, :integer, default: nil
  attr :should_show_branding, :boolean, default: false
  attr :show_language_switcher, :boolean, default: nil
  attr :owner_preview, :boolean, default: false
  attr :demo_mode, :boolean, doc: "handed to the theme extensions only when given"
  slot :inner_block, required: true

  @doc """
  Renders the Rhythm theme wrapper with custom styles and background.
  """
  @spec rhythm_wrapper(map()) :: Phoenix.LiveView.Rendered.t()
  def rhythm_wrapper(assigns) do
    assigns = assigns |> prepare_wrapper_assigns() |> assign(:theme_id, theme_id())

    ~H"""
    <ThemeShell.theme_shell
      class="rhythm-theme-wrapper"
      grid_class="video-background-theme theme-grid"
      language_class="language-switcher-container"
      theme_id={@theme_id}
      theme_tokens={@theme_tokens}
      locale={@locale}
      language_dropdown_open={@language_dropdown_open}
      show_language_switcher={@show_language_switcher}
      owner_preview={@owner_preview}
      organizer_user_id={@organizer_user_id}
      should_show_branding={@should_show_branding}
      {Map.take(assigns, [:demo_mode])}
    >
      <:background>
        <%= cond do %>
          <% @has_video_background -> %>
            <div class="video-background-container" id="rhythm-video-container" phx-hook="RhythmVideo">
              <video
                id="rhythm-background-video-1"
                autoplay
                muted
                loop
                playsinline
                poster={@video_poster}
                class="video-background-video active"
                preload="metadata"
              >
                <.video_sources theme_customization={@theme_customization} />
              </video>
              <video
                id="rhythm-background-video-2"
                muted
                loop
                playsinline
                poster={@video_poster}
                class="video-background-video inactive"
                preload="none"
              >
                <.video_sources theme_customization={@theme_customization} />
              </video>
            </div>
            <.background_motion_toggle />
          <% @theme_customization && get_background_type(@theme_customization) in ["gradient", "color", "image"] -> %>
            <div
              class="video-background-container"
              style={get_background_style(@theme_customization)}
            >
            </div>
          <% true -> %>
            <div class="video-background-container"></div>
        <% end %>
      </:background>
      {render_slot(@inner_block)}
    </ThemeShell.theme_shell>
    """
  end

  defp theme_id do
    {:ok, id} = Catalog.key_to_id(:rhythm)
    id
  end
end
