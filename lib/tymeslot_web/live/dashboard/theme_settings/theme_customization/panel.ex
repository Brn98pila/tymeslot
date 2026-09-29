defmodule TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.Panel do
  @moduledoc """
  A dashboard panel for one option group, drawn inside
  `ThemeCustomizationComponent` for every group the theme's spec lists.

  A panel is a function component module. It writes only through the
  `theme:set_option` event (`phx-value-option` the group's key,
  `phx-value-field`, `phx-value-choice`), targeted at `@myself`, which
  `ThemeCustomizations.apply_option/4` handles through the group's module.
  `Panels.for_group/2` says which panel a group gets.
  """

  @doc """
  Renders the panel. Receives `group` (its descriptor), `customization`,
  `uploads`, `myself` and the panel's UI assigns.
  """
  @callback render(assigns :: map()) :: Phoenix.LiveView.Rendered.t()
end
