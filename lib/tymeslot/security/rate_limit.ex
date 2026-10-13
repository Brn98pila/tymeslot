defmodule Tymeslot.Security.RateLimit do
  @moduledoc """
  Sliding-log rate limiter over one public ETS table.

  Every hit is a row `{bucket_key, seq, inserted_at_us, expires_at_us}`, and a
  hit is allowed while its bucket holds no more than `limit` live rows, its own
  included. Counting individual hits rather than per-window counters means no
  window edge lets twice the limit through.

  `seq` is a node-wide monotonic integer, so every hit is a row of its own: two
  hits on one bucket in the same microsecond both count, and a burst of
  simultaneous requests from one source cannot exceed the limit.

  Denied hits are recorded as well, deliberately. A source that keeps sending
  past its limit stays refused for as long as it keeps sending, rather than
  being let through `limit` times in every window. Every check is linear in
  its bucket's rows, so a bucket keeps only its newest `limit + 1` hits: enough
  to stay over the limit while a flood lasts, and a flood cannot make one
  bucket's checks grow without bound. Once the hits stop, the refusal ends
  when the oldest kept hit expires, which for a flood is one window after it
  stopped.

  Checks run in the caller's process against the table. This process only
  owns the table and sweeps expired rows every `:clean_period`. If it restarts,
  its table goes with it; a check in that gap is allowed and logged once,
  since every bucket starts empty afterwards anyway.
  """

  use GenServer

  require Logger

  @table __MODULE__
  @gap_logged {__MODULE__, :gap_logged}
  @default_clean_period :timer.minutes(1)

  @type key :: String.t()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Charges one hit to `key` and answers whether it is within `limit` hits per
  `window_ms`: `{:allow, count}` with the hits now in the window, or
  `{:deny, wait_ms}` with the time until the oldest kept hit expires.
  """
  @spec hit(key(), pos_integer(), non_neg_integer()) ::
          {:allow, non_neg_integer()} | {:deny, non_neg_integer()}
  def hit(key, window_ms, limit), do: hit(key, window_ms, limit, now())

  @doc false
  @spec hit(key(), pos_integer(), non_neg_integer(), integer()) ::
          {:allow, non_neg_integer()} | {:deny, non_neg_integer()}
  def hit(key, window_ms, limit, now) when is_binary(key) do
    :ets.select_delete(@table, expired(key, now))
    :ets.insert(@table, {key, seq(), now, now + window_ms * 1000})

    live = :ets.select(@table, live(key, now))
    count = length(live)
    kept = trim(live, count, limit + 1)

    if count <= limit, do: {:allow, count}, else: {:deny, wait_ms(kept, now)}
  rescue
    error in ArgumentError -> table_gap(error, __STACKTRACE__, {:allow, 0})
  end

  @doc "How many hits `key` holds inside its window, without charging it."
  @spec get(key(), pos_integer()) :: non_neg_integer()
  def get(key, _window_ms) when is_binary(key) do
    :ets.select_count(@table, [{{key, :_, :_, :"$1"}, [{:>, :"$1", now()}], [true]}])
  rescue
    error in ArgumentError -> table_gap(error, __STACKTRACE__, 0)
  end

  @doc "Drops every hit `key` holds."
  @spec clear(key()) :: :ok
  def clear(key) when is_binary(key) do
    :ets.delete(@table, key)
    :ok
  end

  @doc "Drops every hit in every bucket."
  @spec clear_all() :: :ok
  def clear_all do
    :ets.delete_all_objects(@table)
    :ok
  end

  @doc false
  # Every hit `key` holds, live or not yet swept, as `{inserted_at_us,
  # expires_at_us}`, oldest first. For tests that check what was charged.
  @spec entries(key()) :: [{integer(), integer()}]
  def entries(key) when is_binary(key) do
    @table
    |> :ets.lookup(key)
    |> Enum.sort_by(&elem(&1, 1))
    |> Enum.map(fn {_key, _seq, inserted_at, expires_at} -> {inserted_at, expires_at} end)
  end

  @doc false
  # Every bucket key holding at least one row. For tests.
  @spec keys() :: [key()]
  def keys do
    @table
    |> :ets.select([{{:"$1", :_, :_, :_}, [], [:"$1"]}])
    |> Enum.uniq()
  end

  @doc false
  # Removes every expired row in every bucket; returns how many.
  @spec sweep(integer()) :: non_neg_integer()
  def sweep(now \\ now()) do
    :ets.select_delete(@table, [{{:_, :_, :_, :"$1"}, [{:"=<", :"$1", now}], [true]}])
  end

  @impl GenServer
  def init(opts) do
    :ets.new(@table, [
      :named_table,
      :duplicate_bag,
      :public,
      read_concurrency: true,
      write_concurrency: true,
      decentralized_counters: true
    ])

    :persistent_term.erase(@gap_logged)
    clean_period = Keyword.get(opts, :clean_period, @default_clean_period)
    schedule_clean(clean_period)
    {:ok, clean_period}
  end

  @impl GenServer
  def handle_info(:clean, clean_period) do
    sweep()
    schedule_clean(clean_period)
    {:noreply, clean_period}
  end

  defp schedule_clean(clean_period), do: Process.send_after(self(), :clean, clean_period)

  # Keys are binaries, so they are safe as literals in a match-spec head; a
  # bound key lets ETS go straight to the bucket instead of scanning the table.
  defp expired(key, now), do: [{{key, :_, :_, :"$1"}, [{:"=<", :"$1", now}], [true]}]
  defp live(key, now), do: [{{key, :_, :_, :"$1"}, [{:>, :"$1", now}], [:"$_"]}]

  # Drops the oldest rows past `cap`, returning the rows kept. Concurrent
  # callers trimming the same bucket each drop a prefix of the same order, so
  # together they never leave fewer than `cap` rows.
  defp trim(live, count, cap) when count <= cap, do: live

  defp trim(live, count, cap) do
    {dropped, kept} = live |> Enum.sort_by(&elem(&1, 1)) |> Enum.split(count - cap)
    Enum.each(dropped, &:ets.delete_object(@table, &1))
    kept
  end

  defp wait_ms(rows, now) do
    earliest = rows |> Enum.map(&elem(&1, 3)) |> Enum.min()
    round((earliest - now) / 1000)
  end

  # Only a missing table is the restart gap; any other ArgumentError is a bug.
  defp table_gap(error, stacktrace, answer) do
    if :ets.whereis(@table) != :undefined, do: reraise(error, stacktrace)

    unless :persistent_term.get(@gap_logged, false) do
      :persistent_term.put(@gap_logged, true)
      Logger.warning("Rate limit table missing; allowing checks until it restarts")
    end

    answer
  end

  defp seq, do: System.unique_integer([:monotonic, :positive])

  defp now, do: System.system_time(:microsecond)
end
