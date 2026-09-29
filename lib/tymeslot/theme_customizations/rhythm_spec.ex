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

  # Every shipped preset. A preset added to the catalogue reaches this theme
  # only when listed here. The schemes are in the order the onboarding wizard
  # shows them (the dashboard sorts its own); the background lists are sorted,
  # the order their pickers have always shown.
  @schemes ~w(default turquoise purple sunset ocean forest rose monochrome)
  @gradients ~w(gradient_1 gradient_2 gradient_3 gradient_4 gradient_5 gradient_6 gradient_7 gradient_8)
  @images ~w(preset:artistic-studio preset:elegant-still-life preset:ocean-sunset preset:rustic-farmhouse preset:space-satellite)
  @videos ~w(preset:blue-wave preset:dancing-girl preset:leaves preset:light-green preset:rhythm-default preset:space)

  @impl Spec
  def option_groups,
    do: [
      %{key: :palette, module: Palette, schemes: @schemes},
      %{
        key: :background,
        module: Background,
        kinds: [:gradient, :color, :image, :video],
        gradients: @gradients,
        images: @images,
        videos: @videos
      }
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
