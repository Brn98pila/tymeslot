defmodule Tymeslot.ThemeCustomizations.Tokens do
  @moduledoc """
  What a theme's customisation resolves to for one page view.

    * `vars` are CSS custom properties for the page's `:root`, keyed by full
      property name (`"--theme-primary"`), values without the trailing `;`.
    * `dark_vars` are the same for a dark colour mode. Themes with a single
      mode leave it empty.
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
