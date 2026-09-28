defmodule Tymeslot.ThemeCustomizations.Options.PaletteTest do
  use ExUnit.Case, async: true

  @moduletag :themes
  @moduletag :unit

  alias Ecto.Changeset
  alias Tymeslot.ThemeCustomizations.Options.Palette
  alias Tymeslot.ThemeCustomizations.ThemeCustomizationSchema

  defp changeset(attrs) do
    %ThemeCustomizationSchema{}
    |> Changeset.change()
    |> Palette.changeset(attrs)
  end

  describe "changeset/2" do
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

    test "does not constrain the scheme name while a seed drives the palette" do
      assert changeset(%{"color_scheme" => "neon", "custom_palette_seed" => "#ff6b35"}).valid?
    end
  end

  describe "vars/1" do
    test "emits the preset's colours and its contrast pairs as --theme-* properties" do
      vars = Palette.vars(%{"color_scheme" => "purple", "custom_palette_seed" => nil})

      assert vars["--theme-primary"] == "#8b5cf6"
      assert vars["--theme-text-secondary"] == "#c4b5fd"
      assert vars["--theme-on-primary"] == "#ffffff"
      assert vars["--theme-primary-solid"] == "#8452f5"
    end

    test "derives the palette from the seed when one is stored" do
      vars = Palette.vars(%{"color_scheme" => "purple", "custom_palette_seed" => "#ff6b35"})

      assert vars["--theme-primary"] == "#ff6b35"
    end

    test "emits nothing without a scheme" do
      assert Palette.vars(%{"custom_palette_seed" => "#ff6b35"}) == %{}
    end
  end
end
