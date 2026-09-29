defmodule Tymeslot.ThemeCustomizations.RhythmSpec do
  @moduledoc """
  Customisation spec for Rhythm: a colour palette and every background kind,
  defaulting to Rhythm's own background video.
  """

  use Tymeslot.ThemeCustomizations.Spec

  alias Tymeslot.ThemeCustomizations.Options.Background
  alias Tymeslot.ThemeCustomizations.Options.Palette
  alias Tymeslot.ThemeCustomizations.Spec
  alias Tymeslot.ThemeCustomizations.Tokens

  @impl Spec
  def option_groups,
    do: [
      %{key: :palette, module: Palette},
      %{key: :background, module: Background, kinds: [:gradient, :color, :image, :video]}
    ]

  @impl Spec
  def defaults,
    do: %{
      color_scheme: "default",
      background_type: "video",
      background_value: "preset:rhythm-default"
    }

  @impl Spec
  def tokens(settings, overrides) do
    palette = Palette.vars(settings, overrides)
    background = Background.descriptor(settings)

    %Tokens{
      vars: Map.merge(palette, Background.vars(background, palette)),
      dark_vars: %{},
      background: background
    }
  end
end
