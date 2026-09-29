defmodule Tymeslot.ThemeCustomizations.Options.PaletteTest do
  use ExUnit.Case, async: true

  @moduletag :themes
  @moduletag :unit

  alias Ecto.Changeset
  alias Tymeslot.ThemeCustomizations.Options.Palette

  @group %{key: :palette, module: Palette, schemes: ~w(default forest ocean purple)}

  defp changeset(attrs, group \\ @group) do
    {%{}, Palette.types()}
    |> Changeset.change()
    |> Palette.changeset(attrs, group)
  end

  describe "changeset/3" do
    test "normalises a custom seed to lower-case #rrggbb, three-digit form included" do
      assert Changeset.get_change(
               changeset(%{"custom_palette_seed" => "#FA0"}),
               :custom_palette_seed
             ) ==
               "#ffaa00"
    end

    test "rejects a seed that is not a hex colour" do
      cs = changeset(%{"custom_palette_seed" => "not-hex"})

      refute cs.valid?
      assert {"must be a valid hex colour", _opts} = cs.errors[:custom_palette_seed]
    end

    test "rejects an unknown preset scheme when no seed is set" do
      cs = changeset(%{"color_scheme" => "neon"})

      refute cs.valid?
      assert {"is invalid", _opts} = cs.errors[:color_scheme]
    end

    test "rejects a shipped scheme the group does not list" do
      cs = changeset(%{"color_scheme" => "rose"})

      refute cs.valid?
      assert {"is invalid", _opts} = cs.errors[:color_scheme]
    end

    test "does not constrain the scheme name while a seed drives the palette" do
      assert changeset(%{"color_scheme" => "neon", "custom_palette_seed" => "#ff6b35"}).valid?
    end
  end

  describe "changes/3" do
    test "a scheme drops the custom seed" do
      assert Palette.changes("scheme", "forest", @group) ==
               {:ok, %{"color_scheme" => "forest", "custom_palette_seed" => nil}}
    end

    test "a seed leaves the scheme name alone" do
      assert Palette.changes("seed", "#aabbcc", @group) ==
               {:ok, %{"custom_palette_seed" => "#aabbcc"}}
    end

    test "a blank seed casts to nil and switches back to the preset scheme" do
      assert {:ok, %{"custom_palette_seed" => ""}} = Palette.changes("seed", "", @group)

      cs = changeset(%{"color_scheme" => "forest", "custom_palette_seed" => ""})

      assert Changeset.get_change(cs, :custom_palette_seed) == nil
      assert cs.valid?
    end

    test "any other field is refused" do
      assert Palette.changes("logo", "x.png", @group) == :error
    end
  end

  describe "schemes/1" do
    test "the group's schemes, in the group's order" do
      assert [{"ocean", %{name: "Ocean Breeze"}}, {"forest", %{name: "Forest Green"}}] =
               Palette.schemes(%{@group | schemes: ["ocean", "forest"]})
    end
  end

  describe "resolve/1" do
    test "derives the palette from a stored seed" do
      assert %{name: "Custom", colors: %{primary: "#ff6b35"}} =
               Palette.resolve(%{"color_scheme" => "purple", "custom_palette_seed" => "#ff6b35"})
    end

    test "is the named preset when no seed is stored" do
      assert %{name: "Purple Dream", colors: %{primary: "#8b5cf6"}} =
               Palette.resolve(%{"color_scheme" => "purple", "custom_palette_seed" => nil})
    end

    test "is nil for an unknown scheme and no seed" do
      assert Palette.resolve(%{"color_scheme" => "nonexistent", "custom_palette_seed" => nil}) ==
               nil
    end
  end

  describe "vars/2" do
    test "emits the preset's colours and its contrast pairs as --theme-* properties" do
      vars = Palette.vars(%{"color_scheme" => "purple", "custom_palette_seed" => nil}, %{})

      assert vars["--theme-primary"] == "#8b5cf6"
      assert vars["--theme-text-secondary"] == "#c4b5fd"
      assert vars["--theme-on-primary"] == "#ffffff"
      assert vars["--theme-primary-solid"] == "#8452f5"
    end

    test "emits the palette's background as --theme-canvas, never --theme-background" do
      vars = Palette.vars(%{"color_scheme" => "purple"}, %{})

      assert vars["--theme-canvas"] == "#1e1b4b"
      refute Map.has_key?(vars, "--theme-background")
    end

    test "derives the palette from the seed when one is stored" do
      vars = Palette.vars(%{"color_scheme" => "purple", "custom_palette_seed" => "#ff6b35"}, %{})

      assert vars["--theme-primary"] == "#ff6b35"
    end

    test "emits nothing without a scheme" do
      assert Palette.vars(%{"custom_palette_seed" => "#ff6b35"}, %{}) == %{}
    end
  end
end
