defmodule Tymeslot.ThemeCustomizations.Presets.Covers do
  @moduledoc """
  The cover presets: the wide image across the top of a booking page, for a
  theme with an `Options.Cover` group, which lists the ids it offers.

  Each cover is `%{name:, src:, thumb:}`, `src` and `thumb` its public paths.
  The first four reuse the shipped background images under
  `priv/static/images/themes/backgrounds/` (Pixabay Content Licence, like
  every shipped background) rather than copying them, under the background
  presets' ids and names, so an organiser sees the same image under the same
  name in both pickers. A cover of its own lives under
  `priv/static/images/themes/covers/`, with its Pixabay source URL recorded
  beside its entry.
  """

  @typedoc "A cover preset."
  @type cover_preset :: %{
          required(:name) => String.t(),
          required(:src) => String.t(),
          required(:thumb) => String.t()
        }

  @backgrounds "/images/themes/backgrounds/"

  @covers %{
    "elegant-still-life" => %{
      name: "Elegant Still Life",
      src: @backgrounds <> "elegant-still-life.webp",
      thumb: @backgrounds <> "elegant-still-life-thumbnail.webp"
    },
    "artistic-studio" => %{
      name: "Artistic Studio",
      src: @backgrounds <> "artistic-studio.webp",
      thumb: @backgrounds <> "artistic-studio-thumbnail.webp"
    },
    "ocean-sunset" => %{
      name: "Ocean Sunset",
      src: @backgrounds <> "ocean-sunset.webp",
      thumb: @backgrounds <> "ocean-sunset-thumbnail.webp"
    },
    "rustic-farmhouse" => %{
      name: "Rustic Farmhouse",
      src: @backgrounds <> "rustic-farmhouse.webp",
      thumb: @backgrounds <> "rustic-farmhouse-thumbnail.webp"
    }
  }

  @doc "Every cover preset, keyed by id."
  @spec all() :: %{String.t() => cover_preset()}
  def all, do: @covers
end
