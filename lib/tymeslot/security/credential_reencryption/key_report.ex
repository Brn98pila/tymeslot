defmodule Tymeslot.Security.CredentialReencryption.KeyReport do
  @moduledoc """
  Read-only evidence for retiring an encryption key: how many stored values
  each key version still holds, per table and column.

  Before setting `LEGACY_KEY_RETIRED` the report must show no version `0`
  values, and before removing a key from `DATA_ENCRYPTION_KEYS` none under that
  key's id. `:unreadable` counts the values no configured key opens: corrupt,
  written under a key that is gone, or, with the legacy key retired, possibly
  still on it.

  The report holds counts only, never a value or a ciphertext.
  """

  require Logger

  alias Tymeslot.Infrastructure.Tasks
  alias Tymeslot.Security.CredentialReencryption
  alias Tymeslot.Security.CredentialReencryptionQueries, as: Queries
  alias Tymeslot.Security.Encryption

  @default_batch_size 200
  @boot_check_timeout :timer.minutes(2)

  @typedoc "Values per key version (`0` is the legacy key), plus `:unreadable`."
  @type counts :: %{optional(non_neg_integer() | :unreadable) => non_neg_integer()}

  @type report :: %{
          tables: %{String.t() => %{atom() => counts()}},
          totals: counts()
        }

  @doc """
  Counts the stored values under each key version across every table the
  re-encryption sweep covers. Empty columns are not counted.

  Options: `:batch_size`, rows read per query (default `#{@default_batch_size}`).
  """
  @spec run(keyword()) :: report()
  def run(opts \\ []) do
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)

    tables =
      Map.new(CredentialReencryption.covered_tables(), fn {table, columns} ->
        {table, count_table(table, columns, batch_size)}
      end)

    totals =
      for {_table, columns} <- tables, {_column, counts} <- columns, reduce: %{} do
        acc -> Map.merge(acc, counts, fn _key, a, b -> a + b end)
      end

    %{tables: tables, totals: totals}
  end

  @doc """
  The boot-time check behind `LEGACY_KEY_RETIRED`: when the flag is set, runs
  the report and logs an error naming every `table.column` that holds values no
  configured key opens, with their counts. Does nothing when the flag is unset.

  Bounded: a report that takes longer than #{div(@boot_check_timeout, 1000)} s
  is abandoned with a warning to run it by hand.
  """
  @spec warn_if_retired_key_holds_values() :: :ok
  def warn_if_retired_key_holds_values do
    if Encryption.legacy_key_retired?() do
      task = Tasks.async(fn -> run() end)

      case Task.yield(task, @boot_check_timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, report} -> log_unreadable(report)
        _timed_out_or_crashed -> log_check_incomplete()
      end
    end

    :ok
  end

  defp count_table(table, columns, batch_size) do
    empty = Map.new(columns, &{&1, %{}})

    table
    |> Queries.stream_rows(columns, batch_size)
    |> Enum.reduce(empty, fn row, acc ->
      Enum.reduce(columns, acc, &count_value(&2, &1, Map.get(row, &1)))
    end)
  end

  defp count_value(acc, column, value) do
    case Encryption.key_version(value) do
      :empty -> acc
      {:ok, version} -> bump(acc, column, version)
      {:error, :requires_reencryption} -> bump(acc, column, :unreadable)
    end
  end

  defp bump(acc, column, key) do
    Map.update!(acc, column, fn counts -> Map.update(counts, key, 1, &(&1 + 1)) end)
  end

  defp log_unreadable(%{tables: tables}) do
    unreadable =
      for {table, columns} <- tables,
          {column, %{unreadable: count}} <- columns,
          into: %{},
          do: {"#{table}.#{column}", count}

    if unreadable != %{} do
      listed = Enum.map_join(unreadable, ", ", fn {name, count} -> "#{name}: #{count}" end)

      Logger.error(
        "LEGACY_KEY_RETIRED is set, but stored values no configured key opens remain " <>
          "(#{listed}). If they were written under the legacy key they are not lost: " <>
          "unset LEGACY_KEY_RETIRED, restart, run the re-encryption sweep, and retire " <>
          "the key again once the key report shows no version 0 values.",
        event_type: "encryption_retired_key_values_remain",
        unreadable_values: unreadable
      )
    end
  end

  defp log_check_incomplete do
    Logger.warning(
      "LEGACY_KEY_RETIRED is set, but the check for values still under the legacy key " <>
        "did not finish; run the key report by hand.",
      event_type: "encryption_retired_key_check_incomplete"
    )
  end
end
