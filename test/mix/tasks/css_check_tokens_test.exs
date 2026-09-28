defmodule Mix.Tasks.Css.CheckTokensTest do
  use ExUnit.Case, async: true

  @moduletag :dev_support

  @script "scripts/test_css_tokens.sh"

  setup do
    root = Path.join(System.tmp_dir!(), "css-tokens-#{System.unique_integer([:positive])}")
    modules = Path.join(root, "themes/demo/modules")
    File.mkdir_p!(modules)
    File.mkdir_p!(Path.join(root, "shared/components"))

    File.write!(Path.join(root, "themes/demo/theme.css"), """
    @import "./modules/variables.css";
    @import "./modules/card.css";
    """)

    File.write!(Path.join(modules, "variables.css"), variables_css())
    File.write!(Path.join(modules, "card.css"), ".card {\n  color: var(--ink-1);\n}\n")

    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, modules: modules}
  end

  test "passes when colour literals live only in token files", %{root: root} do
    File.write!(
      Path.join(root, "shared/tokens.css"),
      ":root {\n  --tint: rgba(0, 0, 0, 0.5);\n}\n"
    )

    assert {_output, 0} = run_script(root)
  end

  test "rejects an rgba() literal in a theme module", %{root: root, modules: modules} do
    File.write!(
      Path.join(modules, "card.css"),
      ".card {\n  background: rgba(255, 255, 255, 0.1);\n}\n"
    )

    assert {output, 1} = run_script(root)
    assert output =~ "themes/demo/modules/card.css:2:"
  end

  test "rejects a hex literal in a shared component", %{root: root} do
    File.write!(
      Path.join(root, "shared/components/notice.css"),
      ".notice {\n  color: #fbbf24;\n}\n"
    )

    assert {output, 1} = run_script(root)
    assert output =~ "shared/components/notice.css:2:"
  end

  test "ignores literals inside comments", %{root: root, modules: modules} do
    File.write!(
      Path.join(modules, "card.css"),
      ".card {\n  /* was rgba(0, 0, 0, 0.5) */\n  color: var(--ink-1);\n}\n"
    )

    assert {_output, 0} = run_script(root)
  end

  defp run_script(root) do
    System.cmd("bash", [@script], env: [{"SCHEDULING_CSS_ROOT", root}], stderr_to_stdout: true)
  end

  # Every token the script requires a theme to define, read from the script
  # itself so this fixture follows the list as it grows.
  defp variables_css do
    tokens =
      ~r/^\s+"(--[a-z0-9-]+)"\s*$/m
      |> Regex.scan(File.read!(@script), capture: :all_but_first)
      |> List.flatten()

    ":root {\n" <> Enum.map_join(tokens, "", &"  #{&1}: 0;\n") <> "}\n"
  end
end
