defmodule TymeslotWeb.Themes.Shared.Customization.HelpersTest do
  @moduledoc """
  Covers `assign_theme_customization/3` — the per-tenant customisation entry
  point applied to every booking page mount. Without coverage here, a
  refactor could silently stop applying a tenant's colour/copy/background
  overrides.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :themes
  @moduletag :components

  import Tymeslot.Factory

  alias Phoenix.LiveView.Socket
  alias Tymeslot.ThemeCustomizations.Tokens
  alias TymeslotWeb.Themes.Shared.Customization.Helpers

  defp socket, do: %Socket{assigns: %{__changed__: %{}}}

  describe "assign_theme_customization/3 — no persisted customisation" do
    test "falls back to the theme's defaults" do
      profile = insert(:profile)

      updated = Helpers.assign_theme_customization(socket(), profile, "1")

      assert %Tokens{
               vars: %{
                 "--theme-primary" => "#06b6d4",
                 "--theme-background" => "linear-gradient(" <> _rest
               },
               media: %{background: %{kind: :gradient}}
             } = updated.assigns.theme_tokens

      refute Map.has_key?(updated.assigns, :custom_css)
      refute Map.has_key?(updated.assigns, :customization_options)
    end
  end

  describe "assign_theme_customization/3 — persisted customisation" do
    test "loads the tenant's customisation" do
      profile = insert(:profile)

      _customization =
        insert(:theme_customization,
          profile: profile,
          theme_id: "1",
          color_scheme: "purple",
          background_type: "gradient",
          background_value: "gradient_1"
        )

      updated = Helpers.assign_theme_customization(socket(), profile, "1")

      assert updated.assigns.theme_tokens.vars["--theme-primary"] == "#8b5cf6"
    end

    test "is theme-scoped — a customisation for theme 1 does not leak to theme 2" do
      profile = insert(:profile)

      _theme_one =
        insert(:theme_customization, profile: profile, theme_id: "1", color_scheme: "purple")

      updated_two = Helpers.assign_theme_customization(socket(), profile, "2")

      assert updated_two.assigns.theme_tokens.vars["--theme-primary"] == "#06b6d4"
    end
  end

  describe "assign_theme_customization/3: background" do
    test "hands the wrapper a resolved descriptor, not the raw settings" do
      profile = insert(:profile)

      insert(:theme_customization,
        profile: profile,
        theme_id: "1",
        background_type: "color",
        background_value: "#123456"
      )

      updated = Helpers.assign_theme_customization(socket(), profile, "1")

      assert %Tokens{media: %{background: %{kind: :color, color: "#123456"}}} =
               updated.assigns.theme_tokens

      refute Map.has_key?(updated.assigns, :theme_customization)
      refute Map.has_key?(updated.assigns, :has_custom_theme)
    end
  end

  describe "prepare_wrapper_assigns/1" do
    test "derives the background and the video flag from the tokens' media" do
      video = %{kind: :video, sources: [], poster: nil}

      assigns =
        Helpers.prepare_wrapper_assigns(%{
          __changed__: %{},
          theme_tokens: %Tokens{media: %{background: video}},
          current_state: :schedule
        })

      assert assigns.background == video
      assert assigns.has_video_background
      refute assigns.show_language_switcher
    end

    test "has no background when the media holds none" do
      assigns =
        Helpers.prepare_wrapper_assigns(%{
          __changed__: %{},
          theme_tokens: %Tokens{media: %{logo: "/uploads/logo.png"}},
          current_state: :overview
        })

      assert assigns.background == nil
      refute assigns.has_video_background
      assert assigns.show_language_switcher
    end
  end
end
