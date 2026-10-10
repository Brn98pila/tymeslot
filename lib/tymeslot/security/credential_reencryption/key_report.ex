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

  alias Tymeslot.Emails.EmailScheduler.LinkArg
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
      CredentialReencryption.covered_tables()
      |> Map.new(fn {table, columns} -> {table, count_table(table, columns, batch_size)} end)
      |> Map.put("oban_jobs", %{email_links: count_values(LinkArg.pending_ciphertexts())})

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
      Enum.reduce(columns, acc, fn column, acc ->
        Map.update!(acc, column, &tally(&1, Map.get(row, column)))
      end)
    end)
  end

  defp count_values(values), do: Enum.reduce(values, %{}, &tally(&2, &1))

  defp tally(counts, value) do
    case Encryption.key_version(value) do
      :empty -> counts
      {:ok, version} -> Map.update(counts, version, 1, &(&1 + 1))
      {:error, :requires_reencryption} -> Map.update(counts, :unreadable, 1, &(&1 + 1))
    end
  end

  defp log_unreadable(%{tables: tables}) do
    unreadable =
      for {table, columns} <- tables,
          {column, %{unreadable: count}} <- columns,
          into: %{},
          do: {"#{table}.#{column}", count}

    {email_links, stored} = Map.pop(unreadable, "oban_jobs.email_links")

    if unreadable != %{} do
      Logger.error(
        Enum.join(
          [
            "LEGACY_KEY_RETIRED is set, but values no configured key opens remain."
            | retired_key_advice(stored, email_links)
          ],
          " "
        ),
        event_type: "encryption_retired_key_values_remain",
        unreadable_values: unreadable
      )
    end
  end

  defp retired_key_advice(stored, email_links) do
    stored_advice =
      if stored != %{} do
        listed = Enum.map_join(stored, ", ", fn {name, count} -> "#{name}: #{count}" end)

        "Stored values (#{listed}): if they were written under the legacy key they are " <>
          "not lost; unset LEGACY_KEY_RETIRED, restart, run the re-encryption sweep, and " <>
          "retire the key again once the key report shows no version 0 values."
      end

    # The sweep never touches job args, so these clear only as the emails go out.
    email_advice =
      if email_links do
        "Queued email links (oban_jobs.email_links: #{email_links}): unset " <>
          "LEGACY_KEY_RETIRED and let those emails go out, or accept that their " <>
          "recipients request the links again."
      end

    Enum.reject([stored_advice, email_advice], &is_nil/1)
  end

  defp log_check_incomplete do
    Logger.warning(
      "LEGACY_KEY_RETIRED is set, but the check for values still under the legacy key " <>
        "did not finish; run the key report by hand.",
      event_type: "encryption_retired_key_check_incomplete"
    )
  end
end
