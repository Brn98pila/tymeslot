defmodule Tymeslot.Test.ThemeCustomizations.LogoOption do
  @moduledoc """
  A test-only option group holding an organiser's logo, used to prove that a
  group other than the background can contribute media and own an upload. No
  shipped theme uses it.
  """
  @behaviour Tymeslot.ThemeCustomizations.OptionGroup

  import Ecto.Changeset

  alias Tymeslot.ThemeCustomizations.OptionGroup
  alias Tymeslot.ThemeCustomizations.Validation

  @impl OptionGroup
  def types, do: %{logo_path: :string}

  @impl OptionGroup
  def changeset(changeset, attrs, _group), do: cast(changeset, attrs, [:logo_path])

  @impl OptionGroup
  def changes("logo", "none", _group), do: {:ok, %{"logo_path" => nil}}
  def changes(_field, _value, _group), do: :error

  @impl OptionGroup
  def media(%{"logo_path" => path}, _group) when is_binary(path) and path != "",
    do: %{logo: "/uploads/" <> Validation.sanitize_path(path)}

  def media(_settings, _group), do: %{}
end
