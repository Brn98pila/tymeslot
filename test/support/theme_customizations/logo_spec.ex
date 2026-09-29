defmodule Tymeslot.Test.ThemeCustomizations.LogoSpec do
  @moduledoc """
  A test-only customisation spec: Quill's option groups plus
  `Tymeslot.Test.ThemeCustomizations.LogoOption`, with the generated
  `tokens/2`. It is registered with no theme, so it is exercised through
  `Specs` and the modules that take a spec.
  """
  use Tymeslot.ThemeCustomizations.Spec

  alias Tymeslot.Test.ThemeCustomizations.LogoOption
  alias Tymeslot.ThemeCustomizations.QuillSpec
  alias Tymeslot.ThemeCustomizations.Spec

  @impl Spec
  def option_groups, do: QuillSpec.option_groups() ++ [%{key: :logo, module: LogoOption}]

  @impl Spec
  def defaults, do: QuillSpec.defaults()
end
