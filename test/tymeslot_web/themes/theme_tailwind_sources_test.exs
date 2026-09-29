defmodule TymeslotWeb.Themes.ThemeTailwindSourcesTest do
  @moduledoc """
  Guards the `@source` list in `assets/css/scheduling/shared/entry.css`.

  The theme bundles scan only the theme tree and the web-layer files a booking
  page reaches, so a component a theme starts to call from elsewhere in the
  web layer would lose its utility classes without any build error. This walks
  the remote calls in the compiled theme modules, and in everything they reach
  inside the web layer, and fails for any source file the list leaves out.
  """

  use ExUnit.Case, async: true

  @moduletag :themes
  @moduletag :unit

  @entry_css "assets/css/scheduling/shared/entry.css"

  # Reached from theme code without rendering anything of their own; following
  # them would pull in the whole web layer.
  @not_followed [TymeslotWeb.Router, TymeslotWeb.Endpoint, TymeslotWeb.Gettext]

  test "every web-layer file a booking page reaches is a Tailwind source" do
    sources = tailwind_sources()

    missing =
      reachable_sources()
      |> Enum.reject(&covered?(&1, sources))
      |> Enum.sort()

    assert missing == [],
           "Add these to the @source list in #{@entry_css}:\n" <>
             Enum.map_join(missing, "\n", &Path.relative_to_cwd/1)
  end

  defp tailwind_sources do
    dir = Path.dirname(@entry_css)

    ~r/^@source "([^"]+)";/m
    |> Regex.scan(File.read!(@entry_css), capture: :all_but_first)
    |> Enum.map(fn [path] -> dir |> Path.join(path) |> Path.expand() end)
  end

  defp covered?(file, sources) do
    Enum.any?(sources, &(file == &1 or String.starts_with?(file, &1 <> "/")))
  end

  defp reachable_sources do
    {:ok, modules} = :application.get_key(:tymeslot, :modules)
    web = Map.new(for module <- modules, source = web_source(module), do: {module, source})

    roots =
      for {module, source} <- web,
          String.contains?(source, "/lib/tymeslot_web/themes/"),
          do: module

    web
    |> walk([TymeslotWeb.Layouts | roots], MapSet.new())
    |> Enum.map(&Map.fetch!(web, &1))
    |> Enum.uniq()
  end

  defp walk(_web, [], seen), do: seen

  defp walk(web, [module | rest], seen) do
    if module in seen or module in @not_followed or not Map.has_key?(web, module) do
      walk(web, rest, seen)
    else
      walk(web, callees(module) ++ rest, MapSet.put(seen, module))
    end
  end

  defp web_source(module) do
    source = module.module_info(:compile) |> Keyword.get(:source, []) |> to_string()
    if String.contains?(source, "/lib/tymeslot_web"), do: Path.expand(source)
  end

  defp callees(module) do
    {:ok, {^module, [imports: imports]}} = :beam_lib.chunks(:code.which(module), [:imports])
    imports |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
  end
end
