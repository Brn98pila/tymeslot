defmodule TymeslotWeb.Themes.Shared.Customization.Helpers do
  @moduledoc """
  Helper functions for applying theme customizations to booking pages.
  """
  use Phoenix.Component

  alias Tymeslot.Demo
  alias Tymeslot.ThemeCustomizations
  alias Tymeslot.ThemeCustomizations.Tokens

  @doc """
  Assigns `:theme_tokens` to a socket: the `%Tokens{}` the theme's spec builds
  from the organiser's customisation, or from the theme's defaults when the
  organiser has none, plus the page view's `:theme_overrides` (an embed's
  `?primary-color=`) when the context assigned any.
  """
  @spec assign_theme_customization(Phoenix.LiveView.Socket.t(), map(), String.t()) ::
          Phoenix.LiveView.Socket.t()
  def assign_theme_customization(socket, profile, theme_id) do
    customization = Demo.get_theme_customization(profile.id, theme_id)
    overrides = socket.assigns[:theme_overrides] || %{}

    assign(socket, :theme_tokens, ThemeCustomizations.tokens(theme_id, customization, overrides))
  end

  @doc """
  Prepares common wrapper assigns for theme wrapper components.

  Derives `@background` (the tokens' `media[:background]`, the background
  descriptor, or nil), `@has_video_background` and `@show_language_switcher`
  so each theme wrapper doesn't duplicate this logic; wrappers never read the
  tokens' media themselves.
  """
  @spec prepare_wrapper_assigns(map()) :: map()
  def prepare_wrapper_assigns(assigns) do
    background = background(assigns[:theme_tokens])

    show_language_switcher =
      if is_boolean(assigns[:show_language_switcher]),
        do: assigns[:show_language_switcher],
        else: assigns[:current_state] == :overview

    assigns
    |> assign(:background, background)
    |> assign(:has_video_background, match?(%{kind: :video}, background))
    |> assign(:show_language_switcher, show_language_switcher)
  end

  defp background(%Tokens{media: media}), do: media[:background]
  defp background(_no_tokens), do: nil
end
