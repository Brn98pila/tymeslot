defmodule TymeslotWeb.Themes.Core.RegistryTest do
  use ExUnit.Case, async: true

  @moduletag :themes
  @moduletag :unit

  alias Tymeslot.Themes.Catalog
  alias TymeslotWeb.Themes.Core.Registry
  alias TymeslotWeb.Themes.Core.Registry.Definitions

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

  describe "themes registered through :extra_themes" do
    test "are bound to the module their entry names" do
      assert {:ok, %{key: :fixture, module: TymeslotWeb.Test.FixtureTheme.Theme}} =
               Registry.get_theme_by_id("99")

      assert {:ok, %{id: "99"}} = Registry.get_theme_by_slug("fixture")
    end
  end

  describe "Definitions.build!/2" do
    @facts %{
      alpha: %{id: "1", key: :alpha, name: "Alpha"},
      beta: %{id: "2", key: :beta, name: "Beta"}
    }

    test "binds each Catalog theme to its module by id" do
      assert Definitions.build!(@facts, %{"1" => AlphaTheme, "2" => BetaTheme}) == %{
               alpha: %{id: "1", key: :alpha, name: "Alpha", module: AlphaTheme},
               beta: %{id: "2", key: :beta, name: "Beta", module: BetaTheme}
             }
    end

    test "refuses a Catalog theme with no binding, naming its id" do
      error =
        assert_raise ArgumentError, fn -> Definitions.build!(@facts, %{"1" => AlphaTheme}) end

      assert error.message =~
               ~s(no binding in TymeslotWeb.Themes.Core.Registry's @bindings: ["2"])
    end

    test "refuses a binding with no Catalog theme, naming its id" do
      error =
        assert_raise ArgumentError, fn ->
          Definitions.build!(@facts, %{"1" => AlphaTheme, "2" => BetaTheme, "7" => GammaTheme})
        end

      assert error.message =~ ~s(bindings with no Tymeslot.Themes.Catalog theme: ["7"])
      refute error.message =~ "no binding in"
    end

    test "names both mismatches at once" do
      error =
        assert_raise ArgumentError, fn ->
          Definitions.build!(@facts, %{"1" => AlphaTheme, "7" => GammaTheme})
        end

      assert error.message =~ ~s(["2"])
      assert error.message =~ ~s(["7"])
    end
  end

  describe "the shipped registry" do
    test "holds exactly the Catalog's themes" do
      assert Registry.all_themes() |> Map.keys() |> Enum.sort() ==
               Catalog.all() |> Map.keys() |> Enum.sort()
    end
  end
end
