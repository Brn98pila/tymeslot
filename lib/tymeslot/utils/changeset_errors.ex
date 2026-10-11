defmodule Tymeslot.Utils.ChangesetErrors do
  @moduledoc """
  Picks one error out of a changeset for a single-line message, the same way
  for the web layer's form errors and the domain's own formatters. The caller
  passes the function that turns `{message, opts}` into text, so this module
  translates nothing itself.
  """

  alias Ecto.Changeset

  @type translate :: ({String.t(), keyword()} -> String.t())

  @doc """
  The first field alphabetically, humanised, followed by its first message;
  `nil` when the changeset has no errors.
  """
  @spec first(Changeset.t(), translate()) :: String.t() | nil
  def first(%Changeset{} = changeset, translate) do
    case changeset |> Changeset.traverse_errors(translate) |> Enum.sort_by(&elem(&1, 0)) do
      [{field, errors} | _others] -> "#{humanize(field)} #{first_message(errors)}"
      [] -> nil
    end
  end

  @doc """
  The first message in one field's traversed errors. An embedded or
  associated field nests its errors (a map for one, a list of maps for many);
  its first message is the first one found depth-first.
  """
  @spec first_message(term()) :: String.t() | nil
  def first_message([message | _rest]) when is_binary(message), do: message
  def first_message(nested) when is_list(nested), do: Enum.find_value(nested, &first_message/1)

  def first_message(nested) when is_map(nested),
    do: nested |> Enum.sort_by(&elem(&1, 0)) |> Enum.find_value(&first_message(elem(&1, 1)))

  def first_message(_none), do: nil

  defp humanize(field),
    do: field |> to_string() |> String.replace("_", " ") |> String.capitalize()
end
