defmodule Tymeslot.Themes.CatalogTest do
  use Tymeslot.DataCase, async: true

  @moduletag :themes

  alias Tymeslot.Themes.Catalog

  test "exposes theme facts as the domain source of truth" do
    assert %{quill: %{key: :quill, id: "1"}, rhythm: %{key: :rhythm}} = Catalog.all()

    active = Catalog.active()
    assert Map.keys(active) == [:quill, :rhythm]
    assert Enum.all?(active, fn {_key, theme} -> theme.status == :active end)

    assert %{key: :quill, id: "1", status: :active} = Catalog.default()
    assert Catalog.valid_id?(Catalog.default_id())
  end

  test "holds facts only, not display copy or flow shape" do
    for {_key, facts} <- Catalog.all() do
      refute Map.has_key?(facts, :description)
      refute Map.has_key?(facts.features, :flow_type)
      refute Map.has_key?(facts.features, :step_count)
    end

    assert map_size(Catalog.all()) > 0
  end

  test "gives every theme a heading style" do
    for {_key, facts} <- Catalog.all() do
      assert facts.heading_style in [:named, :generic]
    end

    assert Catalog.default().heading_style == :generic
  end
end
