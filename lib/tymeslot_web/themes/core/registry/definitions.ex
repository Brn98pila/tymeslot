defmodule TymeslotWeb.Themes.Core.Registry.Definitions do
  @moduledoc """
  Joins the catalogue's theme facts to the registry's bindings, for
  `TymeslotWeb.Themes.Core.Registry`, which calls `build!/2` while it
  compiles. A theme is registered in two places (its facts in
  `Tymeslot.Themes.Catalog`, its module in the Registry's `@bindings`), so a
  theme with only one of the two fails the build here, naming the ids and
  what to add. Plain data in and out: this module names no other, so the
  Registry's compile-time dependency on it adds nothing to the compile graph.
  """

  @doc """
  Every theme's facts with its bound module under `:module`, keyed as the
  facts are. Raises `ArgumentError` when a theme in `facts` has no binding
  or a binding names an id `facts` does not hold.
  """
  @spec build!(%{atom() => map()}, %{String.t() => module()}) :: %{atom() => map()}
  def build!(facts, bindings) do
    ids = Enum.map(facts, fn {_key, theme} -> theme.id end)
    unbound = Enum.sort(ids -- Map.keys(bindings))
    unknown = Enum.sort(Map.keys(bindings) -- ids)

    case unbound_problem(unbound) ++ unknown_problem(unknown) do
      [] ->
        Map.new(facts, fn {key, theme} ->
          {key, Map.put(theme, :module, Map.fetch!(bindings, theme.id))}
        end)

      problems ->
        raise ArgumentError, "theme registration: " <> Enum.join(problems, "; ")
    end
  end

  defp unbound_problem([]), do: []

  defp unbound_problem(ids),
    do: [
      "theme ids with no binding in TymeslotWeb.Themes.Core.Registry's @bindings: " <>
        "#{inspect(ids)} (add `\"<id>\" => TymeslotWeb.Themes.<Name>.Theme`)"
    ]

  defp unknown_problem([]), do: []

  defp unknown_problem(ids),
    do: [
      "bindings with no Tymeslot.Themes.Catalog theme: #{inspect(ids)} " <>
        "(add the theme's facts to the Catalog, or remove the binding)"
    ]
end
