defmodule Tymeslot.ThemeCustomizations.PresetsKindsTest do
  @moduledoc """
  Each kind of preset lives in a module of its own under `presets/`, and the
  `Presets` facade answers from them: the per-kind getters return each
  module's `all/0`, and `find_preset_by_id/2` and `take/2` reach every preset
  of every kind.
  """
  use ExUnit.Case, async: true

  @moduletag :themes
  @moduletag :unit

  alias Tymeslot.ThemeCustomizations.Presets
  alias Tymeslot.ThemeCustomizations.Presets.ColourSchemes
  alias Tymeslot.ThemeCustomizations.Presets.Gradients
  alias Tymeslot.ThemeCustomizations.Presets.Images
  alias Tymeslot.ThemeCustomizations.Presets.Videos

  @kinds [
    {:color_scheme, ColourSchemes, &Presets.get_color_schemes/0},
    {:gradient, Gradients, &Presets.get_gradient_presets/0},
    {:image, Images, &Presets.get_image_presets/0},
    {:video, Videos, &Presets.get_video_presets/0}
  ]

  for {kind, module, _getter} <- @kinds do
    @kind kind
    @module module

    describe "#{inspect(module)}" do
      test "holds presets keyed by id" do
        presets = @module.all()

        assert map_size(presets) > 0
        assert Enum.reject(Map.keys(presets), &is_binary/1) == []
        assert Enum.reject(Map.values(presets), &is_binary(&1[:name])) == []
      end

      test "is what the facade finds for #{kind}" do
        assert Enum.reject(@module.all(), fn {id, preset} ->
                 Presets.find_preset_by_id(@kind, id) == preset
               end) == []
      end

      test "is what take/2 returns for #{kind}, in the order asked" do
        ids = @module.all() |> Map.keys() |> Enum.sort(:desc)

        assert Presets.take(@kind, ids) == Enum.map(ids, &{&1, Map.fetch!(@module.all(), &1)})
      end
    end
  end

  test "the per-kind getters are the kind modules' catalogues" do
    for {_kind, module, getter} <- @kinds do
      assert getter.() == module.all()
    end
  end

  test "an unknown kind or id finds nothing" do
    assert Presets.find_preset_by_id(:no_such_kind, "gradient_1") == nil
    assert Presets.find_preset_by_id(:gradient, "gradient_999") == nil
    assert Presets.take(:gradient, ["gradient_999"]) == []
  end
end
