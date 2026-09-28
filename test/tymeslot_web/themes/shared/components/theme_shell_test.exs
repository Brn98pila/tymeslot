defmodule TymeslotWeb.Themes.Shared.Components.ThemeShellTest do
  @moduledoc """
  The page chrome every theme's wrapper renders: the organiser's colours, the
  owner-preview disclosure, the language switcher and the configured theme
  extensions, around the theme's own background and step content.
  """
  # Mutates the node-wide :theme_extensions setting.
  use ExUnit.Case, async: false

  @moduletag :themes
  @moduletag :components

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Tymeslot.ConfigTestHelpers
  alias TymeslotWeb.Themes.Shared.Components.ThemeShell

  defmodule ExtensionProbe do
    use Phoenix.Component

    @spec probe(map()) :: Phoenix.LiveView.Rendered.t()
    def probe(assigns) do
      ~H"""
      <div
        id="extension-probe"
        data-user={@organizer_user_id}
        data-branding={to_string(@should_show_branding)}
        data-theme={@theme_id}
        data-demo={inspect(Map.fetch(assigns, :demo_mode))}
      >
      </div>
      """
    end
  end

  setup do
    ConfigTestHelpers.setup_config(:tymeslot, :theme_extensions, [{ExtensionProbe, :probe}])
  end

  defp render_shell(overrides) do
    {demo, overrides} = Keyword.pop(overrides, :demo_mode, :unset)

    assigns =
      Map.merge(
        %{
          custom_css: nil,
          locale: "en",
          language_dropdown_open: false,
          show_language_switcher: true,
          owner_preview: false,
          grid_style: nil,
          demo_attrs: if(demo == :unset, do: %{}, else: %{demo_mode: demo})
        },
        Map.new(overrides)
      )

    fn assigns ->
      ~H"""
      <ThemeShell.theme_shell
        class="probe-wrapper"
        grid_class="probe-grid theme-grid"
        grid_style={@grid_style}
        language_class="probe-lang"
        theme_id="7"
        custom_css={@custom_css}
        locale={@locale}
        language_dropdown_open={@language_dropdown_open}
        show_language_switcher={@show_language_switcher}
        owner_preview={@owner_preview}
        organizer_user_id={42}
        should_show_branding={true}
        {@demo_attrs}
      >
        <:background>
          <div id="probe-background"></div>
        </:background>
        <p id="probe-step">step</p>
      </ThemeShell.theme_shell>
      """
    end
    |> render_component(assigns)
    |> Floki.parse_fragment!()
  end

  test "writes the organiser's customisation onto :root, and nothing without it" do
    styled = render_shell(custom_css: "--theme-primary: #123456;")

    assert styled |> Floki.find(".probe-wrapper > style") |> Floki.raw_html() =~
             ~r/:root\s*\{\s*--theme-primary: #123456;/

    assert Floki.find(render_shell(custom_css: nil), "style") == []
    assert Floki.find(render_shell(custom_css: ""), "style") == []
  end

  test "renders the background before the grid, and the step inside the content area" do
    doc = render_shell([])

    children =
      doc
      |> Floki.find(".probe-wrapper > *")
      |> Enum.map(fn {tag, attrs, _children} ->
        attrs = Map.new(attrs)
        {tag, attrs["id"] || attrs["class"]}
      end)

    # The grid also carries the `booker-page` hook the shared embed rules
    # (shared/embed.css) size to content.
    assert children == [{"div", "probe-background"}, {"div", "booker-page probe-grid theme-grid"}]

    assert Floki.find(doc, ".probe-grid > .content-area #probe-step") != []
  end

  test "puts the theme's grid style on the grid, and no style attribute without one" do
    doc = render_shell(grid_style: "background: black")

    assert Floki.attribute(doc, ".probe-grid", "style") == ["background: black"]
    assert Floki.attribute(render_shell(grid_style: nil), ".probe-grid", "style") == []
    assert Floki.attribute(render_shell(grid_style: ""), ".probe-grid", "style") == [""]
  end

  test "shows the owner-preview notice only in owner preview" do
    assert Floki.find(render_shell(owner_preview: true), "[data-testid=preview-notice]") != []
    assert Floki.find(render_shell(owner_preview: false), "[data-testid=preview-notice]") == []
  end

  test "shows the language switcher only where the page decided to" do
    assert Floki.find(render_shell(show_language_switcher: true), ".probe-lang.visible") != []
    assert Floki.find(render_shell(show_language_switcher: false), ".probe-lang.hidden") != []

    # A theme hides the container through the semantic class, never by
    # styling the Tailwind utility name.
    assert Floki.find(
             render_shell(show_language_switcher: false),
             ".probe-lang.theme-shell__language--hidden"
           ) != []

    assert Floki.find(render_shell(language_dropdown_open: nil), ".probe-lang") == []
    assert Floki.find(render_shell(locale: nil), ".probe-lang") == []
  end

  test "hands the branding inputs to the theme extensions, in the grid's footer row" do
    doc = render_shell([])

    assert Floki.attribute(doc, ".probe-grid > #extension-probe", "data-user") == ["42"]
    assert Floki.attribute(doc, ".probe-grid > #extension-probe", "data-branding") == ["true"]
  end

  test "hands the theme id to the theme extensions" do
    doc = render_shell([])

    assert Floki.attribute(doc, "#extension-probe", "data-theme") == ["7"]
  end

  test "hands demo mode to the theme extensions only when the page assigned it" do
    assert Floki.attribute(render_shell(demo_mode: true), "#extension-probe", "data-demo") ==
             ["{:ok, true}"]

    assert Floki.attribute(render_shell([]), "#extension-probe", "data-demo") == [":error"]
  end
end
