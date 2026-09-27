defmodule TymeslotWeb.ThemeTestMatrixTest do
  @moduledoc """
  The shared flow suites test exactly the themes `ThemeTestMatrix` lists, so a
  theme missing from it would ship untested by all of them without a single
  red test. This is the red test.
  """
  use ExUnit.Case, async: true

  @moduletag :themes
  @moduletag :unit

  alias Tymeslot.Themes.Catalog
  alias TymeslotWeb.ThemeTestMatrix

  test "has an entry for every catalogue theme, and for nothing else" do
    assert Enum.sort(ThemeTestMatrix.ids()) == Enum.sort(Catalog.valid_ids())
  end

  test "agrees with the catalogue on each theme's key and slug" do
    entries = ThemeTestMatrix.all()
    assert entries != []

    for entry <- entries do
      assert Catalog.id_to_key(entry.id) == {:ok, entry.key}
      assert entry.slug == Atom.to_string(entry.key)
    end
  end

  test "lists themes in numeric id order" do
    ids = ThemeTestMatrix.ids()
    assert ids == Enum.sort_by(ids, &String.to_integer/1)
  end
end
