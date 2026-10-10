defmodule Tymeslot.Infrastructure.RetryTest do
  use ExUnit.Case, async: true

  @moduletag :infrastructure

  import ExUnit.CaptureLog

  alias Tymeslot.Infrastructure.Retry

  # No waiting between attempts.
  @fast [initial_delay: 0, jitter: 0.0]

  defp quietly(fun), do: fun |> with_log() |> elem(0)

  defp counting(results) do
    counter = :counters.new(1, [])

    fun = fn ->
      :counters.add(counter, 1, 1)
      Enum.at(results, :counters.get(counter, 1) - 1, List.last(results))
    end

    {fun, fn -> :counters.get(counter, 1) end}
  end

  describe "with_backoff/2" do
    test "returns a success from the first attempt" do
      {fun, calls} = counting([{:ok, :done}])

      assert {:ok, :done} = Retry.with_backoff(fun, @fast)
      assert calls.() == 1
    end

    test "retries a transient error until the call succeeds" do
      {fun, calls} = counting([{:error, :timeout}, {:error, :econnreset}, {:ok, :done}])

      assert {:ok, :done} = quietly(fn -> Retry.with_backoff(fun, @fast) end)
      assert calls.() == 3
    end

    # Callers report what went wrong; a bare "attempts exceeded" told them
    # nothing about why.
    test "returns the last error, not a placeholder, once the attempts run out" do
      {fun, calls} = counting([{:error, :timeout}, {:error, {:http_error, 503, "busy"}}])

      assert {:error, {:http_error, 503, "busy"}} =
               quietly(fn -> Retry.with_backoff(fun, @fast ++ [max_attempts: 2]) end)

      assert calls.() == 2
    end

    test "does not retry an error the breaker would not count as an outage" do
      for reason <- [:unauthorized, {:http_error, 404, ""}, "Something broke", :circuit_open] do
        {fun, calls} = counting([{:error, reason}, {:ok, :never}])

        assert {:error, ^reason} = Retry.with_backoff(fun, @fast)
        assert calls.() == 1, inspect(reason)
      end
    end

    test "retries the transport failures and statuses the breaker counts" do
      transient = [
        :econnreset,
        :econnrefused,
        :nxdomain,
        {:http_error, 429, ""},
        {:http_error, 502, ""},
        %Mint.TransportError{reason: :closed},
        %Req.TransportError{reason: :timeout}
      ]

      for reason <- transient do
        {fun, calls} = counting([{:error, reason}, {:ok, :done}])

        assert {:ok, :done} = quietly(fn -> Retry.with_backoff(fun, @fast) end)
        assert calls.() == 2, inspect(reason)
      end
    end

    test "uses a caller's own retry rule" do
      {fun, calls} = counting([{:error, :custom}, {:ok, :done}])

      assert {:ok, :done} =
               quietly(fn ->
                 Retry.with_backoff(fun, @fast ++ [retriable?: &(&1 == :custom)])
               end)

      assert calls.() == 2
    end

    test "returns anything else as it is, without retrying" do
      for result <- [:ok, :error, {:error, :a, :b}, nil] do
        {fun, calls} = counting([result])

        assert Retry.with_backoff(fun, @fast) == result
        assert calls.() == 1
      end
    end
  end

  describe "delay/2" do
    test "starts at the initial delay and doubles up to the cap" do
      opts = [initial_delay: 1_000, max_delay: 3_000, jitter: 0.0]

      assert Enum.map(1..4, &Retry.delay(&1, opts)) == [1_000, 2_000, 3_000, 3_000]
    end

    test "jitter varies a delay by at most its fraction either way" do
      delays = for _n <- 1..200, do: Retry.delay(1, initial_delay: 1_000, jitter: 0.1)

      assert Enum.all?(delays, &(&1 in 900..1_100))
      assert length(Enum.uniq(delays)) > 1
    end
  end
end
