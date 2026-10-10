defmodule Tymeslot.Infrastructure.FinchPool.JanitorTest do
  @moduledoc """
  The janitor stops the per-destination pools pinned requests leave on
  `Tymeslot.Finch`, and never one a request is about to use: a pool stopped
  under a request is restarted by Finch with the instance's defaults,
  without the pinned hostname, and every HTTPS request to that destination
  then fails certificate verification.

  Each test runs its own janitor (manual sweeps, no idle grace) on the shared
  Finch instance, over destinations no other test uses.
  """

  use ExUnit.Case, async: false

  @moduletag :infrastructure

  alias Finch.Pool
  alias Tymeslot.Infrastructure.FinchPool.Janitor

  @finch Tymeslot.Finch
  # How many times the race test's sweeper must stop the pool under the holders.
  @min_stops 5

  setup do
    name = {:global, {__MODULE__, System.unique_integer([:positive])}}
    start_supervised!({Janitor, name: name, idle_after: 0, sweep_every: :manual})
    %{janitor: name}
  end

  defp destination do
    n = System.unique_integer([:positive])
    {url_for(n, 0), "pool-#{n}", [conn_opts: [hostname: "pinned-#{n}.example.com"]]}
  end

  # A second address for the same destination: the hostname's DNS moved.
  defp url_for(n, shift),
    do: "https://192.0.2.#{rem(n + shift, 250) + 1}:#{10_000 + rem(n, 50_000)}/hook"

  defp lease!(url, options, tag, janitor) do
    {:ok, lease} = Janitor.lease(url, options, tag, janitor)
    lease
  end

  # `release/2` is a cast; a call queued behind it returns once it is handled.
  defp release!(lease, janitor) do
    :ok = Janitor.release(lease, janitor)
    :sys.get_state(janitor)
  end

  defp pool_alive?(url, tag),
    do: match?({:ok, _pid}, Finch.find_pool(@finch, Pool.new(url, tag: tag)))

  defp pinned_hostname(url, tag) do
    {:ok, pid} = Finch.find_pool(@finch, Pool.new(url, tag: tag))
    %{state: %{opts: %{conn_opts: conn_opts}}} = :sys.get_state(pid)
    conn_opts[:hostname]
  end

  # Sweeps until `expected` pools have been stopped in all, or fails.
  defp sweep_until(janitor, expected, stopped \\ 0, deadline \\ deadline()) do
    stopped = stopped + Janitor.sweep(janitor)

    cond do
      stopped >= expected -> stopped
      System.monotonic_time(:millisecond) > deadline -> stopped
      true -> sweep_until(janitor, expected, stopped, deadline)
    end
  end

  defp deadline, do: System.monotonic_time(:millisecond) + 2_000

  test "stops a pool once its last lease has ended and it has sat idle", %{janitor: janitor} do
    {url, tag, options} = destination()

    lease = lease!(url, options, tag, janitor)
    assert pool_alive?(url, tag)
    release!(lease, janitor)

    assert Janitor.sweep(janitor) == 1
    # The sweep returns only once Finch has forgotten the pool.
    refute pool_alive?(url, tag)
  end

  test "stops every pool a tag covers, one per address", %{janitor: janitor} do
    {_url, tag, options} = destination()
    n = System.unique_integer([:positive])
    {first, second} = {url_for(n, 0), url_for(n, 1)}

    for url <- [first, second], do: release!(lease!(url, options, tag, janitor), janitor)
    assert pool_alive?(first, tag) and pool_alive?(second, tag)

    assert Janitor.sweep(janitor) == 2
    refute pool_alive?(first, tag)
    refute pool_alive?(second, tag)
  end

  test "keeps a pool while a lease on it is outstanding", %{janitor: janitor} do
    {url, tag, options} = destination()

    lease = lease!(url, options, tag, janitor)
    assert Janitor.sweep(janitor) == 0
    assert pool_alive?(url, tag)

    release!(lease, janitor)
  end

  test "keeps a pool idle for less than the threshold" do
    name = {:global, {__MODULE__, :patient, System.unique_integer([:positive])}}

    start_supervised!({Janitor, name: name, idle_after: :timer.hours(1), sweep_every: :manual},
      id: name
    )

    {url, tag, options} = destination()

    release!(lease!(url, options, tag, name), name)

    assert Janitor.sweep(name) == 0
    assert pool_alive?(url, tag)
  end

  # A request that crashes between taking and returning its lease must not
  # keep the pool forever.
  test "ends the lease of a holder that exits", %{janitor: janitor} do
    {url, tag, options} = destination()
    test_pid = self()

    holder =
      spawn(fn ->
        lease!(url, options, tag, janitor)
        send(test_pid, :leased)
        receive do: (:exit -> :ok)
      end)

    assert_receive :leased
    assert Janitor.sweep(janitor) == 0

    send(holder, :exit)

    # The janitor hears of the exit through its own monitor, in its own time.
    assert sweep_until(janitor, 1) == 1
    refute pool_alive?(url, tag)
  end

  test "a pool that cannot be started refuses the lease and keeps the others",
       %{janitor: janitor} do
    {url, tag, options} = destination()
    held = lease!(url, options, tag, janitor)
    pid = GenServer.whereis(janitor)

    {bad_url, bad_tag, _options} = destination()
    assert Janitor.lease(bad_url, [protocols: [:nope]], bad_tag, janitor) == :error

    # Same process, lease intact: the sweep still leaves the leased pool alone.
    assert GenServer.whereis(janitor) == pid
    assert Janitor.sweep(janitor) == 0
    release!(held, janitor)
    assert Janitor.sweep(janitor) == 1
  end

  test "a janitor that is not running refuses leases without failing the caller" do
    absent = {:global, {__MODULE__, :absent, System.unique_integer([:positive])}}
    {url, tag, options} = destination()

    assert Janitor.lease(url, options, tag, absent) == :error
    assert Janitor.release(make_ref(), absent) == :ok
  end

  # The Trap in the ticket: a sweep deciding to stop a pool while a request is
  # about to use it. Leasing and stopping are serialised in the janitor, so
  # every holder must find its pool alive, and still pinned, for as long as
  # it holds the lease, however the sweeps interleave.
  test "a lease taken while sweeps run never sees its pool stopped", %{janitor: janitor} do
    {url, tag, options} = destination()
    hostname = options[:conn_opts][:hostname]

    # Sweeps for as long as the holders run, counting the pools it stops (1)
    # and the sweeps it has made (2).
    stops = :counters.new(2, [])
    sweeper = Task.async(fn -> sweep_until_stopped(janitor, stops) end)

    observations =
      1..8
      |> Task.async_stream(fn _holder -> hold(url, options, tag, hostname, janitor, stops) end,
        max_concurrency: 8,
        timeout: 30_000
      )
      |> Enum.flat_map(fn {:ok, seen} -> seen end)

    send(sweeper.pid, :stop)
    Task.await(sweeper, 30_000)

    assert length(observations) >= 320
    assert Enum.reject(observations, & &1) == []
    # The sweeps did stop the pool between leases, so the leases raced them.
    assert :counters.get(stops, 1) >= @min_stops
  end

  # Takes and returns leases, recording whether each saw its pool alive and
  # pinned, for at least 40 rounds and until the sweeper has stopped the pool
  # often enough that the leases are known to have raced it. Each holder
  # waits for the next sweep before leasing again, so the pool falls idle
  # between rounds and the next lease lands right behind a sweep.
  defp hold(url, options, tag, hostname, janitor, stops, round \\ 1, seen \\ []) do
    lease = lease!(url, options, tag, janitor)
    ok? = pool_alive?(url, tag) and pinned_hostname(url, tag) == hostname
    sweeps = :counters.get(stops, 2)
    :ok = Janitor.release(lease, janitor)
    await_sweep(stops, sweeps)
    seen = [ok? | seen]

    if round >= 40 and :counters.get(stops, 1) >= @min_stops,
      do: seen,
      else: hold(url, options, tag, hostname, janitor, stops, round + 1, seen)
  end

  defp await_sweep(stops, sweeps) do
    if :counters.get(stops, 2) <= sweeps + 1 do
      :erlang.yield()
      await_sweep(stops, sweeps)
    end
  end

  defp sweep_until_stopped(janitor, stops) do
    receive do
      :stop -> :ok
    after
      0 ->
        :counters.add(stops, 1, Janitor.sweep(janitor))
        :counters.add(stops, 2, 1)
        sweep_until_stopped(janitor, stops)
    end
  end
end
