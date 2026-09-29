defmodule TymeslotWeb.Themes.Core.RegistryTest do
  use ExUnit.Case, async: true

  @moduletag :themes
  @moduletag :unit

  alias Tymeslot.Themes.Catalog
  alias TymeslotWeb.Themes.Core.Registry

  describe "default theme" do
    test "is the catalog's default, by id and by key" do
      assert Registry.default_theme_id() == Catalog.default_id()
      assert Registry.default_theme_key() == Catalog.default_key()
      assert {:ok, %{key: key}} = Registry.get_theme_by_id(Registry.default_theme_id())
      assert key == Catalog.default_key()
    end
  end

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
