defmodule TymeslotWeb.ThemeTestMatrix do
  @moduledoc """
  Per-theme test metadata, keyed by theme id.

  The shared flow suites iterate `all/0` instead of listing themes by hand, so
  a theme added to `Tymeslot.Themes.Catalog` is exercised by every one of them
  once it has an entry here. `TymeslotWeb.ThemeTestMatrixTest` fails until it
  does.

  Fields:

    * `:id`, `:key` - as in the catalogue.
    * `:slug` - the key as a string: usernames, test names and the
      `/themes/<slug>/...` payment-return URLs.
    * `:name` - the display name, for failure messages.
    * `:wrapper_class` - the class on the theme's outermost wrapper, whose
      presence proves the theme's own LiveView rendered rather than the
      dispatcher's fallback card.
    * `:video_background` - whether the theme offers a video background, and
      so renders the background motion toggle.
    * `:pins_schedule_actions` - whether the schedule step is locked to the
      viewport with its actions row pinned on-screen (Quill's app shell).
    * `:selected_duration_selector` - matches the overview's
      `[data-testid='duration-option']` card only while it is selected. Each
      theme marks the selection its own way (on the button, or on a wrapper
      around it), so a shared assertion reads the selector from here.
  """

  @type entry :: %{
          id: String.t(),
          key: atom(),
          slug: String.t(),
          name: String.t(),
          wrapper_class: String.t(),
          video_background: boolean(),
          pins_schedule_actions: boolean(),
          selected_duration_selector: String.t()
        }

  @themes %{
    "1" => %{
      id: "1",
      key: :quill,
      slug: "quill",
      name: "Quill",
      wrapper_class: "quill-theme-wrapper",
      video_background: true,
      pins_schedule_actions: true,
      selected_duration_selector: "[data-testid='duration-option'].duration-card--selected"
    },
    "2" => %{
      id: "2",
      key: :rhythm,
      slug: "rhythm",
      name: "Rhythm",
      wrapper_class: "rhythm-theme-wrapper",
      video_background: true,
      pins_schedule_actions: false,
      selected_duration_selector: ".duration-card.selected [data-testid='duration-option']"
    }
  }

  @doc "Every theme's entry, in numeric id order."
  @spec all() :: [entry()]
  def all, do: @themes |> Map.values() |> Enum.sort_by(&String.to_integer(&1.id))

  @doc "Every theme id, in numeric order."
  @spec ids() :: [String.t()]
  def ids, do: Enum.map(all(), & &1.id)

  @doc "One theme's entry; raises for an id the matrix does not know."
  @spec fetch!(String.t()) :: entry()
  def fetch!(id), do: Map.fetch!(@themes, id)
end
