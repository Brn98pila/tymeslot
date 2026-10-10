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

    * `lease/4` starts the pool if needed and records the lease, in one call;
    * the sweep stops only pools with no lease, idle past `:idle_after`, and
      waits for Finch to forget each before handling anything else;
    * a lease ends with `release/2`, or when its holder exits (monitored), so
      a crashed request cannot keep its pool forever.
  """

  use GenServer

  alias Finch.Pool
  alias Tymeslot.Infrastructure.Logging.LogFormat
  require Logger

  @finch Tymeslot.Finch
  @default_idle_after :timer.minutes(5)
  @default_sweep_every :timer.minutes(1)
  @lease_timeout :timer.seconds(5)
  # How long a sweep waits for Finch's registries to forget a stopped pool.
  @unregister_timeout 1_000

  defmodule State do
    @moduledoc false
    @type pool_entry :: %{
            leases: MapSet.t(reference()),
            last_used: integer()
          }
    @type t :: %__MODULE__{
            pools: %{Finch.Pool.t() => pool_entry()},
            leases: %{reference() => Finch.Pool.t()},
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

  `:error` when the pool cannot be started or the janitor does not answer
  (down, restarting, or busy past the timeout); the caller should then go
  without a pool rather than fail the request.
  """
  @spec lease(String.t(), keyword(), String.t(), GenServer.server()) ::
          {:ok, reference()} | :error
  def lease(url, pool_options, tag, server \\ __MODULE__) do
    GenServer.call(server, {:lease, url, pool_options, tag}, @lease_timeout)
  catch
    :exit, reason ->
      Logger.warning("Finch pool lease unavailable", reason: LogFormat.reason(reason))
      :error
  end

  @doc """
  Ends a lease taken with `lease/4`.

  A cast, so ending a lease can never fail the request that held it; a lease
  the janitor never hears about ends with its holder's exit.
  """
  @spec release(reference(), GenServer.server()) :: :ok
  def release(lease, server \\ __MODULE__), do: GenServer.cast(server, {:release, lease})

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
    # Finch keys a pool by scheme, host, port and tag, and a pinned URL names
    # the resolved address, so one tag can cover several pools (a hostname
    # whose DNS rotates). Each is tracked, and stopped, on its own.
    pool = Pool.new(url, tag: tag)

    case start_pool(pool, pool_options) do
      :ok ->
        # The monitor's reference doubles as the lease: a holder that exits
        # releases it through its :DOWN message.
        lease = Process.monitor(holder)

        entry =
          state.pools
          |> Map.get(pool, %{leases: MapSet.new(), last_used: now()})
          |> Map.update!(:leases, &MapSet.put(&1, lease))

        {:reply, {:ok, lease},
         %{
           state
           | pools: Map.put(state.pools, pool, entry),
             leases: Map.put(state.leases, lease, pool)
         }}

      {:error, reason} ->
        Logger.warning("Finch pool could not be started", reason: LogFormat.reason(reason))
        {:reply, :error, state}
    end
  end

  def handle_call(:sweep, _from, state) do
    {stopped, state} = stop_idle(state)
    {:reply, stopped, state}
  end

  @impl GenServer
  def handle_cast({:release, lease}, state) do
    Process.demonitor(lease, [:flush])
    {:noreply, end_lease(state, lease)}
  end

  @impl GenServer
  def handle_info({:DOWN, lease, :process, _holder, _reason}, state),
    do: {:noreply, end_lease(state, lease)}

  def handle_info(:sweep, state) do
    {_stopped, state} = stop_idle(state)
    schedule_sweep(state)
    {:noreply, state}
  end

  # Finch raises on invalid options and on an instance that is not running,
  # and exits when its pool supervisor does: none of that may take the
  # janitor, and every lease it holds, down with it. (A start error other
  # than already started surfaces as a CaseClauseError from inside Finch.)
  defp start_pool(pool, pool_options) do
    Finch.start_pool(@finch, pool, pool_options)
  rescue
    exception -> {:error, exception}
  catch
    :exit, reason -> {:error, reason}
  end

  defp end_lease(state, lease) do
    case Map.pop(state.leases, lease) do
      {nil, _leases} ->
        state

      {pool, leases} ->
        pools =
          Map.update!(state.pools, pool, fn entry ->
            %{entry | leases: MapSet.delete(entry.leases, lease), last_used: now()}
          end)

        %{state | pools: pools, leases: leases}
    end
  end

  defp stop_idle(state) do
    cutoff = now() - state.idle_after

    {idle, in_use} =
      Enum.split_with(state.pools, fn {_pool, entry} ->
        MapSet.size(entry.leases) == 0 and entry.last_used <= cutoff
      end)

    Enum.each(idle, fn {pool, _entry} -> stop_pool(pool) end)
    {length(idle), %{state | pools: Map.new(in_use)}}
  end

  # A pool already gone (its supervisor restarted, say) needs no stopping.
  defp stop_pool(pool) do
    case Finch.stop_pool(@finch, pool) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end

    await_unregistered(pool, System.monotonic_time(:millisecond) + @unregister_timeout)
  catch
    :exit, _reason -> :ok
  end

  # Finch's registries drop a stopped pool's entries only once they process
  # its exit, and until then a lookup returns the dead pids: a lease taken
  # in that window would skip starting the pool, and its request would reach
  # a dead one. So the janitor handles no lease until both have caught up.
  defp await_unregistered(pool, deadline) do
    cond do
      unregistered?(pool) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        Logger.warning("Stopped Finch pool still registered", tag: pool.tag)

      true ->
        Process.sleep(1)
        await_unregistered(pool, deadline)
    end
  end

  defp unregistered?(pool) do
    Finch.find_pool(@finch, pool) == :error and
      Finch.get_pool_count(@finch, pool) == {:error, :not_found}
  catch
    # The pool supervisor's entry outlived its process.
    :exit, _reason -> false
  end

  defp schedule_sweep(%State{sweep_every: :manual}), do: :ok
  defp schedule_sweep(%State{sweep_every: every}), do: Process.send_after(self(), :sweep, every)

  defp now, do: System.monotonic_time(:millisecond)
end
