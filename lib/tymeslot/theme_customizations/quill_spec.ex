defmodule Tymeslot.ThemeCustomizations.QuillSpec do
  @moduledoc """
  Customisation spec for Quill: a colour palette and every background kind,
  defaulting to the Aurora gradient. Reads and writes the `color_scheme`,
  `custom_palette_seed` and `background_*` columns.
  """

  alias Tymeslot.ThemeCustomizations.Options.Background
  alias Tymeslot.ThemeCustomizations.Options.Palette
  alias Tymeslot.ThemeCustomizations.Spec
  alias Tymeslot.ThemeCustomizations.Tokens

  @behaviour Spec

  @background_kinds [:gradient, :color, :image, :video]

  @impl Spec
  def option_groups,
    do: [
      %{key: :palette, type: :palette},
      %{key: :background, type: :background, kinds: @background_kinds}
    ]

  @impl Spec
  def defaults,
    do: %{color_scheme: "default", background_type: "gradient", background_value: "gradient_1"}

  @impl Spec
  def changeset(changeset, attrs) do
    changeset
    |> Palette.changeset(attrs)
    |> Background.changeset(attrs, @background_kinds)
  end

  @impl Spec
  def tokens(settings, _overrides),
    do: %Tokens{vars: Map.merge(Palette.vars(settings), Background.vars(settings))}

  @impl Spec
  def asset_fields, do: Background.asset_fields()
end
