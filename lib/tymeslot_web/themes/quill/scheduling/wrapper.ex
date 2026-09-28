defmodule TymeslotWeb.Themes.Quill.Scheduling.Wrapper do
  @moduledoc """
  The Quill theme's wrapper: its video or gradient background and wrapper
  classes around the shared `ThemeShell`.
  """
  use Phoenix.Component

  alias Tymeslot.Themes.Catalog
  alias TymeslotWeb.Themes.Shared.Components.ThemeShell

  import TymeslotWeb.Components.BackgroundMotionToggle,
    only: [background_motion_toggle: 1]

  import TymeslotWeb.Themes.Shared.Customization.Helpers
  import TymeslotWeb.Themes.Shared.VideoSources, only: [video_sources: 1]

  attr :theme_customization, :map, default: nil
  attr :custom_css, :string, default: nil
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
  Renders the Quill theme wrapper with custom styles and background.
  """
  @spec quill_wrapper(map()) :: Phoenix.LiveView.Rendered.t()
  def quill_wrapper(assigns) do
    assigns = assigns |> prepare_wrapper_assigns() |> assign(:theme_id, theme_id())

    ~H"""
    <ThemeShell.theme_shell
      class="quill-theme-wrapper theme-1"
      grid_class={["main-gradient theme-grid", @has_video_background && "has-video-background"]}
      grid_style={
        if @theme_customization && !@has_video_background,
          do: get_background_style(@theme_customization),
          else: ""
      }
      language_class="fixed top-6 right-6 z-50 language-switcher-wrapper"
      theme_id={@theme_id}
      custom_css={@custom_css}
      locale={@locale}
      language_dropdown_open={@language_dropdown_open}
      show_language_switcher={@show_language_switcher}
      owner_preview={@owner_preview}
      organizer_user_id={@organizer_user_id}
      should_show_branding={@should_show_branding}
      {Map.take(assigns, [:demo_mode])}
    >
      <:background :if={@has_video_background}>
        <div class="video-background" id="quill-video-container" phx-hook="QuillVideo">
          <video
            autoplay
            muted
            loop
            playsinline
            preload="metadata"
            poster={@video_poster}
            class="video-background"
          >
            <.video_sources theme_customization={@theme_customization} />
          </video>
        </div>
        <.background_motion_toggle />
      </:background>
      {render_slot(@inner_block)}
    </ThemeShell.theme_shell>
    """
  end

  defp theme_id do
    {:ok, id} = Catalog.key_to_id(:quill)
    id
  end
end
