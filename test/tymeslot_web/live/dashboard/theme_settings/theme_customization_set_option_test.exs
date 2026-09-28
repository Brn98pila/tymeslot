defmodule TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomizationSetOptionTest do
  @moduledoc """
  The customisation panel is generated from the theme's spec, and every
  option write is one event, `theme:set_option`, backed by
  `ThemeCustomizations.apply_option/4`.
  """
  use TymeslotWeb.LiveCase, async: true

  @moduletag :themes
  @moduletag :live

  import Tymeslot.DashboardTestHelpers

  alias Tymeslot.ThemeCustomizations

  setup :setup_dashboard_user_with_theme

  defp option_button(option, field, value),
    do:
      "button[phx-click='theme:set_option'][phx-value-option='#{option}']" <>
        "[phx-value-field='#{field}'][phx-value-value='#{value}']"

  defp set_option(view, params),
    do:
      view
      |> with_target("#theme-customization-uploads")
      |> render_click("theme:set_option", params)

  describe "theme:set_option" do
    test "a scheme card saves the palette", %{conn: conn, profile: profile} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/theme/customize/1")

      view |> element(option_button("palette", "scheme", "ocean")) |> render_click()

      assert ThemeCustomizations.get_by_profile_and_theme(profile.id, "1").color_scheme == "ocean"
    end

    test "a gradient card saves the background", %{conn: conn, profile: profile} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/theme/customize/1")

      view |> element(option_button("background", "gradient", "gradient_4")) |> render_click()

      saved = ThemeCustomizations.get_by_profile_and_theme(profile.id, "1")
      assert {saved.background_type, saved.background_value} == {"gradient", "gradient_4"}
    end

    test "the colour widget commits through the same event", %{conn: conn, profile: profile} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/theme/customize/1")
      view |> element("button", "Solid Color") |> render_click()
      view |> element("button[phx-click='theme:toggle_custom_picker']") |> render_click()

      assert has_element?(
               view,
               ~s(#custom-background-picker[data-event="theme:set_option"][data-commit-params='{"field":"color","option":"background"}'])
             )

      view
      |> element("#custom-background-picker")
      |> render_hook("theme:set_option", %{
        "option" => "background",
        "field" => "color",
        "value" => "#123456"
      })

      assert ThemeCustomizations.get_by_profile_and_theme(profile.id, "1").background_value ==
               "#123456"
    end

    test "emits the unchanged telemetry event", %{conn: conn, profile: profile} do
      ref = make_ref()
      parent = self()
      handler_id = "set-option-telemetry-#{inspect(ref)}"

      :telemetry.attach(
        handler_id,
        [:tymeslot, :theme_customization, :color_scheme_changed],
        fn _event, _measurements, metadata, _config ->
          if metadata.profile_id == profile.id, do: send(parent, {:telemetry, ref, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      {:ok, view, _html} = live(conn, ~p"/dashboard/theme/customize/1")
      view |> element(option_button("palette", "scheme", "ocean")) |> render_click()

      assert_receive {:telemetry, ^ref, %{scheme_id: "ocean", theme_id: "1"}}
    end

    test "an option the theme does not declare is ignored", %{conn: conn, profile: profile} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/theme/customize/1")

      set_option(view, %{"option" => "logo", "field" => "file", "value" => "x.png"})

      assert ThemeCustomizations.get_by_profile_and_theme(profile.id, "1") == nil
      assert render(view) =~ "Color Palette"
    end

    test "a background kind the theme does not declare is refused with a message",
         %{conn: conn, profile: profile} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/theme/customize/1")

      set_option(view, %{"option" => "background", "field" => "pattern", "value" => "stripes"})

      assert render(view) =~ "This option is not available for this theme."
      assert ThemeCustomizations.get_by_profile_and_theme(profile.id, "1") == nil
    end

    test "an invalid value is refused and nothing is saved", %{conn: conn, profile: profile} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/theme/customize/1")

      set_option(view, %{
        "option" => "background",
        "field" => "gradient",
        "value" => "gradient_999"
      })

      assert render(view) =~ "Could not save your theme customization"
      assert ThemeCustomizations.get_by_profile_and_theme(profile.id, "1") == nil
    end

    test "a malformed payload is ignored", %{conn: conn, profile: profile} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/theme/customize/1")

      set_option(view, %{"option" => "palette"})

      assert ThemeCustomizations.get_by_profile_and_theme(profile.id, "1") == nil
    end
  end

  describe "panels from the spec" do
    # Quill and Rhythm both declare a palette and a background with all four
    # kinds; a new theme gets its own expectations.
    for theme_id <- ["1", "2"] do
      test "theme #{theme_id}: one panel per option group, with the declared background tabs",
           %{conn: conn} do
        {:ok, _view, html} = live(conn, "/dashboard/theme/customize/#{unquote(theme_id)}")

        assert html =~ "Color Palette"
        assert html =~ "Background Design"

        for kind <- ~w(gradient color image video) do
          assert html =~ ~s(phx-value-type="#{kind}"), "missing the #{kind} tab"
        end
      end
    end
  end
end
