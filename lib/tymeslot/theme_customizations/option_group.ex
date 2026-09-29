defmodule Tymeslot.ThemeCustomizations.OptionGroup do
  @moduledoc """
  The contract of a customisation option group.

  A theme spec's `option_groups/0` lists group descriptors: maps carrying the
  group's `key`, the `module` implementing this behaviour, and whatever else
  that module reads from its descriptor (a background group's `kinds`, for
  instance). Shared code handles a group only through its module, so a new
  kind of option is one new module and no edit to any shared file:

    * `types/0`: the settings the group stores, with their Ecto types;
    * `changeset/3`: casts and validates them, refusing anything the
      descriptor does not offer;
    * `changes/3`: the settings one dashboard or onboarding choice writes,
      or `:error` for a field or value the group does not have;
    * `asset_fields/1` (optional): the settings that hold uploaded files and
      the kind of each. A module without it has none.
  """

  alias Ecto.Changeset
  alias Tymeslot.ThemeCustomizations.Spec

  @typedoc "A group descriptor, as a spec's `option_groups/0` lists it."
  @type group :: %{
          required(:key) => atom(),
          required(:module) => module(),
          optional(atom()) => term()
        }

  @doc "The settings the group stores, with their Ecto types."
  @callback types() :: %{atom() => atom()}

  @doc """
  Casts and validates the group's settings on the spec's schemaless
  changeset, refusing what `group` does not offer.
  """
  @callback changeset(Changeset.t(), map(), group()) :: Changeset.t()

  @doc """
  The settings one choice writes (`field` and `value` as the dashboard or
  onboarding send them), or `:error` for a field or value the group does not
  have.
  """
  @callback changes(field :: String.t(), value :: String.t(), group()) :: {:ok, map()} | :error

  @doc "The settings that hold uploaded files, and what each stores."
  @callback asset_fields(group()) :: [{atom(), Spec.asset_kind()}]

  @optional_callbacks asset_fields: 1

  @doc "A group's upload settings; empty when its module has no `asset_fields/1`."
  @spec asset_fields(group()) :: [{atom(), Spec.asset_kind()}]
  def asset_fields(%{module: module} = group) do
    if exports?(module, :asset_fields, 1), do: module.asset_fields(group), else: []
  end

  # A group module is named in a spec's data, not called at compile time, so
  # it may not be loaded yet when `function_exported?/3` asks.
  defp exports?(module, function, arity),
    do: Code.ensure_loaded?(module) and function_exported?(module, function, arity)
end
