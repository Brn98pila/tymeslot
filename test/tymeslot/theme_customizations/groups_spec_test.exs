defmodule Tymeslot.Test.ThemeCustomizations.GroupsSpecTest do
  @moduledoc """
  The shared option groups, declared together on a test-only spec
  (`test/support/theme_customizations/groups_spec.ex`) and driven through
  `Specs` and the spec's generated callbacks, as a theme's spec would use
  them. None of the shared modules knows the spec exists.
  """
  use ExUnit.Case, async: true

  @moduletag :themes
  @moduletag :unit

  alias Ecto.Changeset
  alias Tymeslot.Test.ThemeCustomizations.GroupsSpec
  alias Tymeslot.ThemeCustomizations.Options.Accent
  alias Tymeslot.ThemeCustomizations.Options.Palette
  alias Tymeslot.ThemeCustomizations.Specs

  defp defaults, do: Map.new(GroupsSpec.defaults(), fn {k, v} -> {Atom.to_string(k), v} end)

  defp validate(attrs) do
    {%{}, Specs.setting_types(GroupsSpec)}
    |> Changeset.change()
    |> GroupsSpec.changeset(attrs)
  end

  describe "settings" do
    test "are every declared group's" do
      assert Specs.setting_types(GroupsSpec) == Map.merge(Palette.types(), Accent.types())
    end

    test "the defaults pass the generated changeset" do
      assert validate(defaults()).valid?
    end
  end

  describe "accent" do
    test "the generated changeset refuses an accent the group does not list" do
      changeset = validate(Map.put(defaults(), "accent", "chartreuse"))

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :accent)
    end

    test "the stored accent is the page's primary, in both colour sets" do
      tokens = GroupsSpec.tokens(Map.put(defaults(), "accent", "cobalt"), %{})

      assert tokens.vars["--theme-primary"] == "#2563eb"
      assert tokens.dark_vars["--theme-primary"] == "#4a7eee"
    end

    test "the group's default applies when no accent is stored" do
      tokens = GroupsSpec.tokens(Map.delete(defaults(), "accent"), %{})

      assert tokens.vars["--theme-primary"] == "#077995"
      assert tokens.dark_vars["--theme-primary"] == "#0891b2"
    end

    test "an embed's primary colour wins over the stored accent" do
      tokens =
        GroupsSpec.tokens(Map.put(defaults(), "accent", "cobalt"), %{primary_color: "#e11d48"})

      assert tokens.vars["--theme-primary"] == "#e11d48"
      assert tokens.dark_vars["--theme-primary"] == "#e64065"
    end
  end
end
