defmodule Tymeslot.Infrastructure.FinchPool.Janitor do
  @moduledoc """
  Starts the tagged pools `FinchPool` serves pinned requests from, and stops
  them again once nothing has used them for a while.

  Every pinned request (one SSRF-guarded call to a webhook, CalDAV server,
  calendar feed or self-hosted video server) gets a pool tagged by its
  destination's resolved address and connection options. Destinations are
  user-supplied and DNS moves, so without this a long-running node kept one
  idle pool for every destination it had ever contacted.

  Stopping a pool is safe only if no request is about to use it. A request
  that found its pool alive and then had it stopped would reach Finch with
  no pool under its tag, and Finch starts one itself, with the instance's
  default configuration: without the pinned hostname, so every HTTPS request
  to that destination fails certificate verification for as long as the node
  runs. So a request takes a *lease* first, and the lease is granted in the
  same process, and so in the same order, as pools are started and stopped:

    * `lease/2` starts the pool if needed and records the lease, in one call;
    * the sweep stops only pools with no lease, idle past `:idle_after`;
    * a lease ends with `release/1`, or when its holder exits (monitored), so
      a crashed request cannot keep its pool forever.
  """

  use GenServer

  alias Finch.Pool

  @finch Tymeslot.Finch
  @default_idle_after :timer.minutes(5)
  @default_sweep_every :timer.minutes(1)

  defmodule State do
    @moduledoc false
    @type pool_entry :: %{
            pool: Finch.Pool.t(),
            leases: MapSet.t(reference()),
            last_used: integer()
          }
    @type t :: %__MODULE__{
            pools: %{String.t() => pool_entry()},
            leases: %{reference() => String.t()},
            idle_after: non_neg_integer(),
            sweep_every: pos_integer() | :manual
          }
    defstruct pools: %{}, leases: %{}, idle_after: 0, sweep_every: :manual
  end

  @doc """
  Options: `:idle_after` (ms a pool may sit unused before it is stopped,
  default five minutes) and `:sweep_every` (ms between sweeps, default one
  minute, or `:manual` to sweep only through `sweep/1`).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Whether the janitor is running, and so whether leases can be taken."
  @spec running?(GenServer.server()) :: boolean()
  def running?(server \\ __MODULE__), do: GenServer.whereis(server) != nil

  @doc """
  Ensures a pool tagged `tag` for `url` exists with `pool_options`, and
  leases it to the calling process until `release/2` or the caller's exit.
  """
  @spec lease(String.t(), keyword(), String.t(), GenServer.server()) :: reference()
  def lease(url, pool_options, tag, server \\ __MODULE__),
    do: GenServer.call(server, {:lease, url, pool_options, tag})

  @doc "Ends a lease taken with `lease/4`."
  @spec release(reference(), GenServer.server()) :: :ok
  def release(lease, server \\ __MODULE__), do: GenServer.call(server, {:release, lease})

  @doc "Stops every pool idle past the threshold now; returns how many it stopped."
  @spec sweep(GenServer.server()) :: non_neg_integer()
  def sweep(server \\ __MODULE__), do: GenServer.call(server, :sweep)

  @impl GenServer
  def init(opts) do
    state = %State{
      idle_after: Keyword.get(opts, :idle_after, @default_idle_after),
      sweep_every: Keyword.get(opts, :sweep_every, @default_sweep_every)
    }

    schedule_sweep(state)
    {:ok, state}
  end

  @impl GenServer
  def handle_call({:lease, url, pool_options, tag}, {holder, _tag}, state) do
    pool = Pool.new(url, tag: tag)
    :ok = Finch.start_pool(@finch, pool, pool_options)

    # The monitor's reference doubles as the lease: a holder that exits
    # releases it through its :DOWN message.
    lease = Process.monitor(holder)

    entry =
      state.pools
      |> Map.get(tag, %{pool: pool, leases: MapSet.new(), last_used: now()})
      |> Map.update!(:leases, &MapSet.put(&1, lease))

    {:reply, lease,
     %{state | pools: Map.put(state.pools, tag, entry), leases: Map.put(state.leases, lease, tag)}}
  end

  def handle_call({:release, lease}, _from, state) do
    Process.demonitor(lease, [:flush])
    {:reply, :ok, end_lease(state, lease)}
  end

  def handle_call(:sweep, _from, state) do
    {stopped, state} = stop_idle(state)
    {:reply, stopped, state}
  end

  @impl GenServer
  def handle_info({:DOWN, lease, :process, _holder, _reason}, state),
    do: {:noreply, end_lease(state, lease)}

  def handle_info(:sweep, state) do
    {_stopped, state} = stop_idle(state)
    schedule_sweep(state)
    {:noreply, state}
  end

  defp end_lease(state, lease) do
    case Map.pop(state.leases, lease) do
      {nil, _leases} ->
        state

      {tag, leases} ->
        pools =
          Map.update!(state.pools, tag, fn entry ->
            %{entry | leases: MapSet.delete(entry.leases, lease), last_used: now()}
          end)

        %{state | pools: pools, leases: leases}
    end
  end

  defp stop_idle(state) do
    cutoff = now() - state.idle_after

    {idle, in_use} =
      Enum.split_with(state.pools, fn {_tag, entry} ->
        MapSet.size(entry.leases) == 0 and entry.last_used <= cutoff
      end)

    Enum.each(idle, fn {_tag, %{pool: pool}} -> stop_pool(pool) end)
    {length(idle), %{state | pools: Map.new(in_use)}}
  end

  # A pool already gone (its supervisor restarted, say) needs no stopping.
  defp stop_pool(pool) do
    case Finch.stop_pool(@finch, pool) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end
  end

  defp schedule_sweep(%State{sweep_every: :manual}), do: :ok
  defp schedule_sweep(%State{sweep_every: every}), do: Process.send_after(self(), :sweep, every)

  defp now, do: System.monotonic_time(:millisecond)
end
