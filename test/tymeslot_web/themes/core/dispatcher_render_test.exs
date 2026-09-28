defmodule TymeslotWeb.Themes.Core.DispatcherRenderTest do
  @moduledoc """
  The dispatcher's fallback when no theme can draw the page: an id that
  resolves to no theme shows the error card.
  """

  use ExUnit.Case, async: true

  @moduletag :themes
  @moduletag :unit

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias TymeslotWeb.Themes.Core.Dispatcher

  defp render(assigns) do
    %{__changed__: nil}
    |> Map.merge(assigns)
    |> Dispatcher.render()
    |> rendered_to_string()
  end

  test "an id that resolves to no theme shows the error card" do
    html = render(%{theme_id: "9", live_action: :cancel})

    assert html =~ "Theme Error"
    assert html =~ "Theme not found"
  end
end
