defmodule TymeslotWeb.Test.FixtureTheme.Scheduling.Wrapper do
  @moduledoc "The fixture theme's wrapper: the shared `ThemeShell`, with no background."
  use Phoenix.Component

  alias Tymeslot.Themes.Catalog
  alias TymeslotWeb.Themes.Shared.Components.ThemeShell

  import TymeslotWeb.Themes.Shared.Customization.Helpers, only: [prepare_wrapper_assigns: 1]

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

  @spec fixture_wrapper(map()) :: Phoenix.LiveView.Rendered.t()
  def fixture_wrapper(assigns) do
    assigns = assigns |> prepare_wrapper_assigns() |> assign(:theme_id, theme_id())

    ~H"""
    <ThemeShell.theme_shell
      class="fixture-theme-wrapper"
      grid_class="fixture-theme-grid"
      language_class="fixture-theme-language"
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
      {render_slot(@inner_block)}
    </ThemeShell.theme_shell>
    """
  end

  defp theme_id do
    {:ok, id} = Catalog.key_to_id(:fixture)
    id
  end
end
