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
  """

  @type entry :: %{
          id: String.t(),
          key: atom(),
          slug: String.t(),
          name: String.t(),
          wrapper_class: String.t(),
          video_background: boolean(),
          pins_schedule_actions: boolean()
        }

  @themes %{
    "1" => %{
      id: "1",
      key: :quill,
      slug: "quill",
      name: "Quill",
      wrapper_class: "quill-theme-wrapper",
      video_background: true,
      pins_schedule_actions: true
    },
    "2" => %{
      id: "2",
      key: :rhythm,
      slug: "rhythm",
      name: "Rhythm",
      wrapper_class: "rhythm-theme-wrapper",
      video_background: true,
      pins_schedule_actions: false
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
