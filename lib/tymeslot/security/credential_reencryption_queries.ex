defmodule Tymeslot.Security.CredentialReencryptionQueries do
  @moduledoc """
  Data access for the credential re-encryption sweep.

  Reads encrypted columns in keyset-paginated batches and writes migrated values
  back a row at a time. Schemaless queries keep the sweep decoupled from the
  individual integration schemas — it operates purely on table names and column
  lists supplied by `Tymeslot.Security.CredentialReencryption`.
  """

  import Ecto.Query

  alias Tymeslot.Repo

  @doc """
  Fetches up to `limit` rows of the given table with `id > after_id` (every
  row from the start for a `nil` `after_id`), ordered by `id`, selecting only
  the id and the requested columns. The id may be an integer or a UUID, which
  comes back as its raw bytes and is passed back the same way.

  Option `:present`: only rows where that column is not null.
  """
  @spec fetch_batch(
          String.t(),
          [atom()],
          integer() | binary() | nil,
          pos_integer(),
          keyword()
        ) :: [map()]
  def fetch_batch(table, columns, after_id, limit, opts \\ []) do
    fields = [:id | columns]

    query =
      from(r in table,
        order_by: [asc: r.id],
        limit: ^limit,
        select: map(r, ^fields)
      )

    query
    |> after_id(after_id)
    |> present(opts[:present])
    |> Repo.all()
  end

  @doc """
  Streams every row of the table as `fetch_batch/5` pages it, `batch_size`
  rows per query, so a caller walks a whole table without loading it. Takes
  `fetch_batch/5`'s options.
  """
  @spec stream_rows(String.t(), [atom()], pos_integer(), keyword()) :: Enumerable.t()
  def stream_rows(table, columns, batch_size, opts \\ []) do
    # The first page starts from no id rather than 0, since some of the tables
    # are keyed by UUID.
    {:after, nil}
    |> Stream.unfold(fn {:after, after_id} ->
      case fetch_batch(table, columns, after_id, batch_size, opts) do
        [] -> nil
        rows -> {rows, {:after, rows |> List.last() |> Map.fetch!(:id)}}
      end
    end)
    |> Stream.concat()
  end

  defp present(query, nil), do: query
  defp present(query, column), do: where(query, [r], not is_nil(field(r, ^column)))

  defp after_id(query, nil), do: query
  defp after_id(query, id), do: where(query, [r], r.id > ^id)

  @doc """
  Writes the given column updates for a single row, one column at a time,
  each guarded by a compare-and-swap against the ciphertext it was read with.

  `updates` is a list of `{column, old_ciphertext, new_ciphertext}` tuples. A
  column is only written when its current value still matches
  `old_ciphertext` — if a concurrent writer changed or deleted the row
  between the batch read and this call, that column's update affects zero
  rows and is silently skipped rather than clobbering the newer value.

  Returns the number of columns written: `0` when every CAS lost (and for the
  no-op case of an empty `updates` list).
  """
  @spec update_row(String.t(), integer() | binary(), [{atom(), binary(), binary()}]) ::
          non_neg_integer()
  def update_row(table, id, updates) do
    Enum.count(updates, fn {column, old_value, new_value} ->
      query =
        from(r in table,
          where: r.id == ^id and field(r, ^column) == ^old_value
        )

      match?({1, _returned}, Repo.update_all(query, set: [{column, new_value}]))
    end)
  end
end
