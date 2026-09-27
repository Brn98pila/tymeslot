defmodule TymeslotWeb.Themes.Core.ThemeInfoTest do
  use ExUnit.Case, async: true

  @moduletag :themes
  @moduletag :unit

  alias TymeslotWeb.Themes.Core.ThemeInfo

  describe "theme_options/0" do
    test "offers every shipping theme by name, in id order" do
      assert ThemeInfo.theme_options() == [{"Quill", "1"}, {"Rhythm", "2"}]
    end
  end

  describe "theme_options/1" do
    test "hides beta themes, so one can ship before it is offered" do
      themes = %{
        quill: %{id: "1", name: "Quill", status: :active},
        next: %{id: "3", name: "Next", status: :beta}
      }

      assert ThemeInfo.theme_options(themes) == [{"Quill", "1"}]
    end

    test "sorts ids numerically, not as strings" do
      themes = %{
        ten: %{id: "10", name: "Ten", status: :active},
        two: %{id: "2", name: "Two", status: :active},
        one: %{id: "1", name: "One", status: :active}
      }

      assert ThemeInfo.theme_options(themes) == [{"One", "1"}, {"Two", "2"}, {"Ten", "10"}]
    end
  end
end
