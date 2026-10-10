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

  setup do
    name = :"janitor_test_#{System.unique_integer([:positive])}"
    start_supervised!({Janitor, name: name, idle_after: 0, sweep_every: :manual})
    %{janitor: name}
  end

  defp destination do
    n = System.unique_integer([:positive])
    url = "https://192.0.2.#{rem(n, 250) + 1}:#{10_000 + rem(n, 50_000)}/hook"
    {url, "pool-#{n}", [conn_opts: [hostname: "pinned-#{n}.example.com"]]}
  end

  defp pool_alive?(url, tag),
    do: match?({:ok, _pid}, Finch.find_pool(@finch, Pool.new(url, tag: tag)))

  defp pinned_hostname(url, tag) do
    {:ok, pid} = Finch.find_pool(@finch, Pool.new(url, tag: tag))
    %{state: %{opts: %{conn_opts: conn_opts}}} = :sys.get_state(pid)
    conn_opts[:hostname]
  end

  test "stops a pool once its last lease has ended and it has sat idle", %{janitor: janitor} do
    {url, tag, options} = destination()

    lease = Janitor.lease(url, options, tag, janitor)
    assert pool_alive?(url, tag)
    :ok = Janitor.release(lease, janitor)

    assert Janitor.sweep(janitor) == 1
    refute pool_alive?(url, tag)
  end

  test "keeps a pool while a lease on it is outstanding", %{janitor: janitor} do
    {url, tag, options} = destination()

    lease = Janitor.lease(url, options, tag, janitor)
    assert Janitor.sweep(janitor) == 0
    assert pool_alive?(url, tag)

    :ok = Janitor.release(lease, janitor)
  end

  test "keeps a pool idle for less than the threshold" do
    name = :"janitor_patient_#{System.unique_integer([:positive])}"

    start_supervised!({Janitor, name: name, idle_after: :timer.hours(1), sweep_every: :manual},
      id: name
    )

    {url, tag, options} = destination()

    :ok = Janitor.release(Janitor.lease(url, options, tag, name), name)

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
        Janitor.lease(url, options, tag, janitor)
        send(test_pid, :leased)
        receive do: (:exit -> :ok)
      end)

    assert_receive :leased
    assert Janitor.sweep(janitor) == 0

    ref = Process.monitor(holder)
    send(holder, :exit)
    assert_receive {:DOWN, ^ref, :process, ^holder, _reason}

    assert Janitor.sweep(janitor) == 1
    refute pool_alive?(url, tag)
  end

  # The Trap in the ticket: a sweep deciding to stop a pool while a request is
  # about to use it. Leasing and stopping are serialised in the janitor, so
  # every holder must find its pool alive, and still pinned, for as long as
  # it holds the lease, however the sweeps interleave.
  test "a lease taken while sweeps run never sees its pool stopped", %{janitor: janitor} do
    {url, tag, options} = destination()
    hostname = options[:conn_opts][:hostname]

    sweeper =
      Task.async(fn ->
        Enum.reduce(1..300, 0, fn _n, stopped -> stopped + Janitor.sweep(janitor) end)
      end)

    observations =
      1..8
      |> Task.async_stream(
        fn _holder ->
          for _round <- 1..40 do
            lease = Janitor.lease(url, options, tag, janitor)
            seen = pool_alive?(url, tag) and pinned_hostname(url, tag) == hostname
            :ok = Janitor.release(lease, janitor)
            seen
          end
        end,
        max_concurrency: 8,
        timeout: 30_000
      )
      |> Enum.flat_map(fn {:ok, seen} -> seen end)

    stopped = Task.await(sweeper, 30_000)

    assert length(observations) == 320
    assert Enum.reject(observations, & &1) == []
    # The sweeps did stop the pool between leases, so the leases raced them.
    assert stopped > 0
  end
end
