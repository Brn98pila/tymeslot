defmodule Tymeslot.ThemeCustomizations.Presets do
  @moduledoc """
  The preset catalogue (colour schemes, gradients, image and video backgrounds)
  and lookups over it. The single place preset data lives.
  """

  @typedoc "A palette's colours, keyed `primary`, `primary_hover`, `secondary`, `accent`, `background`, `surface`, `text`, `text_secondary`."
  @type colours :: %{atom() => String.t()}

  @typedoc """
  A colour scheme. `colors` is the set for `mode`; a `:light` scheme may carry
  `dark_colors`, its counterpart for a theme that follows the visitor's OS. A
  `:dark` scheme never has `dark_colors`.
  """
  @type color_scheme_preset :: %{
          required(:name) => String.t(),
          required(:mode) => :light | :dark,
          required(:colors) => colours(),
          optional(:dark_colors) => colours()
        }
  @type gradient_preset :: %{required(:name) => String.t(), required(:value) => String.t()}
  @type image_preset :: %{
          required(:name) => String.t(),
          required(:file) => String.t(),
          required(:thumbnail) => String.t(),
          required(:description) => String.t()
        }
  @type video_preset :: %{
          required(:name) => String.t(),
          required(:file) => String.t(),
          required(:thumbnail) => String.t(),
          required(:poster) => String.t(),
          required(:description) => String.t()
        }
  @type preset :: color_scheme_preset() | gradient_preset() | image_preset() | video_preset()

  @color_schemes %{
    "default" => %{
      name: "Default Turquoise",
      mode: :dark,
      colors: %{
        primary: "#06b6d4",
        primary_hover: "#0891b2",
        secondary: "#14b8a6",
        accent: "#10b981",
        background: "#0f172a",
        surface: "rgba(30, 41, 59, 0.5)",
        text: "#e2e8f0",
        text_secondary: "#94a3b8"
      }
    },
    "turquoise" => %{
      name: "Arctic Blue",
      mode: :dark,
      colors: %{
        primary: "#0284c7",
        primary_hover: "#0369a1",
        secondary: "#0ea5e9",
        accent: "#38bdf8",
        background: "#0c1426",
        surface: "rgba(15, 23, 42, 0.6)",
        text: "#e0f2fe",
        text_secondary: "#7dd3fc"
      }
    },
    "purple" => %{
      name: "Purple Dream",
      mode: :dark,
      colors: %{
        primary: "#8b5cf6",
        primary_hover: "#7c3aed",
        secondary: "#a78bfa",
        accent: "#c084fc",
        background: "#1e1b4b",
        surface: "rgba(46, 38, 84, 0.5)",
        text: "#ede9fe",
        text_secondary: "#c4b5fd"
      }
    },
    "sunset" => %{
      name: "Sunset Glow",
      mode: :dark,
      colors: %{
        primary: "#f97316",
        primary_hover: "#ea580c",
        secondary: "#fb923c",
        accent: "#fbbf24",
        background: "#431407",
        surface: "rgba(92, 45, 10, 0.5)",
        text: "#fef3c7",
        text_secondary: "#fed7aa"
      }
    },
    "ocean" => %{
      name: "Ocean Breeze",
      mode: :dark,
      colors: %{
        primary: "#0ea5e9",
        primary_hover: "#0284c7",
        secondary: "#38bdf8",
        accent: "#7dd3fc",
        background: "#082f49",
        surface: "rgba(12, 74, 110, 0.5)",
        text: "#e0f2fe",
        text_secondary: "#bae6fd"
      }
    },
    "forest" => %{
      name: "Forest Green",
      mode: :dark,
      colors: %{
        primary: "#10b981",
        primary_hover: "#059669",
        secondary: "#34d399",
        accent: "#6ee7b7",
        background: "#052e16",
        surface: "rgba(20, 83, 45, 0.5)",
        text: "#d1fae5",
        text_secondary: "#a7f3d0"
      }
    },
    "rose" => %{
      name: "Rose Gold",
      mode: :dark,
      colors: %{
        primary: "#f43f5e",
        primary_hover: "#e11d48",
        secondary: "#fb7185",
        accent: "#fda4af",
        background: "#4c0519",
        surface: "rgba(136, 19, 55, 0.5)",
        text: "#ffe4e6",
        text_secondary: "#fecdd3"
      }
    },
    "monochrome" => %{
      name: "Monochrome",
      mode: :dark,
      colors: %{
        primary: "#6b7280",
        primary_hover: "#4b5563",
        secondary: "#9ca3af",
        accent: "#d1d5db",
        background: "#111827",
        surface: "rgba(31, 41, 55, 0.5)",
        text: "#f3f4f6",
        text_secondary: "#d1d5db"
      }
    }
  }

  @gradients %{
    "gradient_1" => %{
      name: "Aurora",
      value: "linear-gradient(135deg, #667eea 0%, #764ba2 100%)"
    },
    "gradient_2" => %{
      name: "Ocean",
      value: "linear-gradient(135deg, #2E3192 0%, #1BFFFF 100%)"
    },
    "gradient_3" => %{
      name: "Sunset",
      value: "linear-gradient(135deg, #FC466B 0%, #3F5EFB 100%)"
    },
    "gradient_4" => %{
      name: "Forest",
      value: "linear-gradient(135deg, #11998e 0%, #38ef7d 100%)"
    },
    "gradient_5" => %{
      name: "Berry",
      value: "linear-gradient(135deg, #4e54c8 0%, #8f94fb 100%)"
    },
    "gradient_6" => %{
      name: "Midnight",
      value: "linear-gradient(135deg, #0f0c29 0%, #302b63 50%, #24243e 100%)"
    },
    "gradient_7" => %{
      name: "Coral",
      value: "linear-gradient(135deg, #fa709a 0%, #fee140 100%)"
    },
    "gradient_8" => %{
      name: "Northern Lights",
      value: "linear-gradient(135deg, #43cea2 0%, #185a9d 100%)"
    }
  }

  @videos %{
    "preset:rhythm-default" => %{
      name: "Rhythm Default",
      file: "rhythm-background-desktop.webm",
      thumbnail: "rhythm-background-thumbnail.jpg",
      poster: "rhythm-background-poster.jpg",
      description: "Default Rhythm theme video"
    },
    "preset:blue-wave" => %{
      name: "Blue Wave",
      file: "blue-wave-desktop.mp4",
      thumbnail: "blue-wave-thumbnail.jpg",
      poster: "blue-wave-poster.jpg",
      description: "Flowing blue wave animation"
    },
    "preset:dancing-girl" => %{
      name: "Dancing Girl",
      file: "dancing-girl-desktop.mp4",
      thumbnail: "dancing-girl-thumbnail.jpg",
      poster: "dancing-girl-poster.jpg",
      description: "Elegant dancing silhouette"
    },
    "preset:leaves" => %{
      name: "Falling Leaves",
      file: "leaves-desktop.mp4",
      thumbnail: "leaves-thumbnail.jpg",
      poster: "leaves-poster.jpg",
      description: "Peaceful autumn leaves falling"
    },
    "preset:light-green" => %{
      name: "Light Green",
      file: "light-green-desktop.mp4",
      thumbnail: "light-green-thumbnail.jpg",
      poster: "light-green-poster.jpg",
      description: "Soothing light green abstract"
    },
    "preset:space" => %{
      name: "Space Journey",
      file: "space-desktop.mp4",
      thumbnail: "space-thumbnail.jpg",
      poster: "space-poster.jpg",
      description: "Cosmic space exploration"
    }
  }

  @images %{
    "preset:artistic-studio" => %{
      name: "Artistic Studio",
      file: "artistic-studio.webp",
      thumbnail: "artistic-studio-thumbnail.webp",
      description: "Creative artistic workspace scene"
    },
    "preset:rustic-farmhouse" => %{
      name: "Rustic Farmhouse",
      file: "rustic-farmhouse.webp",
      thumbnail: "rustic-farmhouse-thumbnail.webp",
      description: "Cozy farmhouse still life with rustic charm"
    },
    "preset:space-satellite" => %{
      name: "Space Satellite",
      file: "space-satellite.webp",
      thumbnail: "space-satellite-thumbnail.webp",
      description: "Modern satellite technology in space"
    },
    "preset:elegant-still-life" => %{
      name: "Elegant Still Life",
      file: "elegant-still-life.webp",
      thumbnail: "elegant-still-life-thumbnail.webp",
      description: "Sophisticated still life composition"
    },
    "preset:ocean-sunset" => %{
      name: "Ocean Sunset",
      file: "ocean-sunset.webp",
      thumbnail: "ocean-sunset-thumbnail.webp",
      description: "Peaceful ocean sunset with surfer silhouette"
    }
  }

  @doc """
  Gets all color scheme definitions.
  """
  @spec get_color_schemes() :: %{String.t() => color_scheme_preset()}
  def get_color_schemes, do: @color_schemes

  @doc """
  Gets all gradient preset definitions.
  """
  @spec get_gradient_presets() :: %{String.t() => gradient_preset()}
  def get_gradient_presets, do: @gradients

  @doc """
  Gets all video preset definitions.
  """
  @spec get_video_presets() :: %{String.t() => video_preset()}
  def get_video_presets, do: @videos

  @doc """
  Gets all image preset definitions.
  """
  @spec get_image_presets() :: %{String.t() => image_preset()}
  def get_image_presets, do: @images

  @doc """
  The presets of one type that `ids` names, as `{id, preset}` in the order
  given. An id the catalogue does not hold is left out.
  """
  @spec take(:color_scheme | :gradient | :video | :image, [String.t()]) ::
          [{String.t(), preset()}]
  def take(preset_type, ids) do
    Enum.flat_map(ids, fn id ->
      case find_preset_by_id(preset_type, id) do
        nil -> []
        preset -> [{id, preset}]
      end
    end)
  end

  @doc """
  Finds a specific preset by type and ID.
  """
  @spec find_preset_by_id(:color_scheme | :gradient | :video | :image, String.t()) ::
          preset() | nil
  def find_preset_by_id(preset_type, preset_id) do
    case preset_type do
      :color_scheme -> Map.get(get_color_schemes(), preset_id)
      :gradient -> Map.get(get_gradient_presets(), preset_id)
      :video -> Map.get(get_video_presets(), preset_id)
      :image -> Map.get(get_image_presets(), preset_id)
      _other_type -> nil
    end
  end
end
