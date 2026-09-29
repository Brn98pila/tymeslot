defmodule Tymeslot.ThemeCustomizations.Tokens do
  @moduledoc """
  What a theme's customisation resolves to for one page view.

    * `vars` are CSS custom properties for the page's `:root`, keyed by full
      property name (`"--theme-primary"`), values without the trailing `;`.
    * `dark_vars` are the same for a visitor whose OS is in dark mode,
      written inside `@media (prefers-color-scheme: dark)`. A palette fills
      them only for a light scheme with a dark counterpart in a group with
      `follow_os: true`; otherwise they are empty and the page keeps `vars`.
    * `background` is a structured description of the page background for the
      theme wrapper to render (`%{kind: :gradient | :color | :image | :video, ...}`),
      or `nil` when no background resolved.
  """

  @type css_vars :: %{optional(String.t()) => String.t()}
  @type background ::
          %{required(:kind) => :gradient | :color | :image | :video, optional(atom()) => term()}
          | nil

  @type t :: %__MODULE__{vars: css_vars(), dark_vars: css_vars(), background: background()}

  defstruct vars: %{}, dark_vars: %{}, background: nil
end
