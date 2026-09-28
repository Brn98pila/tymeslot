defmodule TymeslotWeb.Live.Scheduling.ThemeUtils do
  @moduledoc """
  Shared utilities for theme-specific LiveViews.

  This module provides common functionality that can be used across different
  themes while maintaining their independence.
  """

  import Phoenix.Component, only: [assign: 3]

  alias TymeslotWeb.Live.Scheduling.PreviewMode
  alias TymeslotWeb.Themes.Core.Registry

  @doc """
  Assigns theme-related data including preview mode detection.

  `?theme=` selects which theme renders, and nothing else. A page is a preview
  only when the URL carries `?preview=` (`PreviewMode.claimed?/1`), which sets
  `:theme_preview`.

  `:theme_preview` is a claim, not an authorisation, and it is load-bearing in
  two different ways. It tunes rendering (the `iframe_embed.js` standalone
  bail-out), and it makes `BookingSubmissionHandlerComponent` fail a booking
  closed when no valid owner token backs the claim, so that a preview whose
  token expired mid-session cannot silently persist a real meeting the owner
  never sees. Whether a booking is simulated rather than blocked hangs off the
  verified, owner-bound `:owner_preview` token instead (see
  `LiveHelpers.assign_owner_preview/2`).

  Because the claim can block a booking, it must never be inferrable from a
  parameter a visitor can pick up by accident. That is why `?theme=` no longer
  counts: see `PreviewMode`.
  """
  @spec assign_theme_with_preview(Phoenix.LiveView.Socket.t(), map()) ::
          Phoenix.LiveView.Socket.t()
  def assign_theme_with_preview(socket, params) do
    theme_id =
      Registry.requested_theme_id(params) || socket.assigns[:theme_id] ||
        Registry.default_theme_id()

    socket
    |> assign(:scheduling_theme_id, theme_id)
    |> assign(:theme_preview, PreviewMode.claimed?(params))
  end
end
