defmodule TymeslotWeb.Themes.Shared.CustomQuestions.EventsTest do
  use ExUnit.Case, async: true

  @moduletag :scheduling
  @moduletag :themes

  alias Phoenix.LiveView.Socket
  alias TymeslotWeb.Themes.Shared.CustomQuestions.Events

  defp socket, do: %Socket{assigns: %{__changed__: %{}}}

  test "relays a theme's own event untouched on the questions step" do
    assert {:noreply, _socket} = Events.handle_event("theme:hint", %{"q" => "2"}, socket())
    assert_received {:step_event, :questions, "theme:hint", %{"q" => "2"}}
  end

  test "ignores any other event rather than crashing the page" do
    assert {:noreply, _socket} = Events.handle_event("next_slide", %{}, socket())
    refute_received {:step_event, _step, _event, _data}
  end
end
