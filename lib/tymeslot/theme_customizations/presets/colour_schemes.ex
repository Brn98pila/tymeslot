defmodule Tymeslot.ThemeCustomizations.Presets.ColourSchemes do
  @moduledoc """
  The colour-scheme presets. Read through `Tymeslot.ThemeCustomizations.Presets`;
  a theme offers a scheme only when its palette group lists the id.

  The light tones (`neutral`, `cool`, `warm`) carry their dark set in
  `dark_colors`, for a palette group with `follow_os: true`; their names are
  registered for the dashboard (`dashboard_appearance`) and translated where
  they are shown. Every tone has the same primary family, since the accent
  group that goes with them replaces it.
  """
  use Gettext, backend: TymeslotWeb.Gettext

  @typedoc "A palette's colours, keyed `primary`, `primary_hover`, `secondary`, `accent`, `background`, `surface`, `text`, `text_secondary`."
  @type colours :: %{atom() => String.t()}

  @typedoc """
  A colour scheme. `colors` is the set for `mode`; a `:light` scheme may carry
  `dark_colors`, its counterpart for a theme that follows the visitor's OS. A
  `:dark` scheme never has `dark_colors`.
  """
  @type preset :: %{
          required(:name) => String.t(),
          required(:mode) => :light | :dark,
          required(:colors) => colours(),
          optional(:dark_colors) => colours()
        }

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
    },
    "neutral" => %{
      name: dgettext_noop("dashboard_appearance", "Neutral"),
      mode: :light,
      colors: %{
        primary: "#0e7490",
        primary_hover: "#155e75",
        secondary: "#0891b2",
        accent: "#0d9488",
        background: "#f5f5f5",
        surface: "#ffffff",
        text: "#111111",
        text_secondary: "#5f6368"
      },
      dark_colors: %{
        primary: "#22d3ee",
        primary_hover: "#06b6d4",
        secondary: "#67e8f9",
        accent: "#2dd4bf",
        background: "#0e0e10",
        surface: "#18181b",
        text: "#f4f4f5",
        text_secondary: "#a1a1aa"
      }
    },
    "cool" => %{
      name: dgettext_noop("dashboard_appearance", "Cool"),
      mode: :light,
      colors: %{
        primary: "#0e7490",
        primary_hover: "#155e75",
        secondary: "#0891b2",
        accent: "#0d9488",
        background: "#f1f5f9",
        surface: "#ffffff",
        text: "#0f172a",
        text_secondary: "#606f85"
      },
      dark_colors: %{
        primary: "#22d3ee",
        primary_hover: "#06b6d4",
        secondary: "#67e8f9",
        accent: "#2dd4bf",
        background: "#0b1120",
        surface: "#131c2e",
        text: "#e2e8f0",
        text_secondary: "#94a3b8"
      }
    },
    "warm" => %{
      name: dgettext_noop("dashboard_appearance", "Warm"),
      mode: :light,
      colors: %{
        primary: "#0e7490",
        primary_hover: "#155e75",
        secondary: "#0891b2",
        accent: "#0d9488",
        background: "#f7f5f2",
        surface: "#fffdfa",
        text: "#1c1917",
        text_secondary: "#756e6a"
      },
      dark_colors: %{
        primary: "#22d3ee",
        primary_hover: "#06b6d4",
        secondary: "#67e8f9",
        accent: "#2dd4bf",
        background: "#151210",
        surface: "#1f1b18",
        text: "#f5f5f4",
        text_secondary: "#a8a29e"
      }
    }
  }

  @doc "Every colour scheme, keyed by id."
  @spec all() :: %{String.t() => preset()}
  def all, do: @color_schemes
end
