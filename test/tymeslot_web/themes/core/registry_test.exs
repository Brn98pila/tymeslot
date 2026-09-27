defmodule TymeslotWeb.Themes.Core.RegistryTest do
  use ExUnit.Case, async: true

  @moduletag :themes
  @moduletag :unit

  alias Tymeslot.Themes.Catalog
  alias TymeslotWeb.Themes.Core.Registry

  describe "get_theme_by_slug/1" do
    test "finds every catalogue theme by its key as a string" do
      themes = Catalog.all()
      assert map_size(themes) > 0

      for {key, %{id: id}} <- themes do
        assert {:ok, %{id: ^id, key: ^key}} = Registry.get_theme_by_slug(Atom.to_string(key))
      end
    end

    test "does not find an unknown slug, and creates no atom for it" do
      slug = "no-such-theme-#{System.unique_integer([:positive])}"

      assert Registry.get_theme_by_slug(slug) == {:error, :theme_not_found}
      assert_raise ArgumentError, fn -> String.to_existing_atom(slug) end
    end
  end
end
