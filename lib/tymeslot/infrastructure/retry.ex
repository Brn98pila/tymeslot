defmodule Tymeslot.Infrastructure.Retry do
  @moduledoc """
  Retries a call with exponential backoff and jitter while it fails with a
  transient error.

  The function returns `{:ok, _}` or `{:error, reason}`; anything else is
  returned as it is, without retrying. Whether `reason` is worth another
  attempt is decided by `:retriable?`, by default
  `Tymeslot.Infrastructure.BreakerOutcome.transient?/1`, the rule the circuit
  breakers count failures by. When the attempts run out, or the error is not
  retriable, the last `{:error, reason}` is returned, so the caller still
  knows what failed.
  """

  alias Tymeslot.Infrastructure.BreakerOutcome
  alias Tymeslot.Infrastructure.Logging.LogFormat

  require Logger

  @default_opts [
    max_attempts: 3,
    initial_delay: 1_000,
    max_delay: 16_000,
    jitter: 0.25,
    retriable?: &BreakerOutcome.transient?/1
  ]

  @type opts :: [
          max_attempts: pos_integer(),
          initial_delay: non_neg_integer(),
          max_delay: non_neg_integer(),
          jitter: float(),
          retriable?: (term() -> boolean())
        ]

  @doc """
  Runs `fun`, retrying it while it returns a retriable `{:error, reason}`.

  ## Options

    * `:max_attempts` - attempts in all, the first included (default 3)
    * `:initial_delay` - delay before the second attempt, in ms (default 1000);
      each later delay doubles
    * `:max_delay` - cap on any one delay, in ms (default 16000)
    * `:jitter` - each delay varies by up to this fraction either way
      (default 0.25; 0.0 for none)
    * `:retriable?` - whether an error reason is worth another attempt
      (default `BreakerOutcome.transient?/1`)
  """
  @spec with_backoff((-> result), opts()) :: result when result: term()
  def with_backoff(fun, opts \\ []) when is_function(fun, 0) do
    run(fun, 1, Keyword.merge(@default_opts, opts))
  end

  @doc """
  The delay before attempt `attempt + 1`, in ms: `initial_delay` doubled for
  each attempt after the first, capped at `max_delay`, varied by `jitter`.
  """
  @spec delay(pos_integer(), opts()) :: non_neg_integer()
  def delay(attempt, opts) do
    opts = Keyword.merge(@default_opts, opts)
    capped = min(round(opts[:initial_delay] * :math.pow(2, attempt - 1)), opts[:max_delay])
    spread = round(capped * opts[:jitter])

    if spread > 0,
      do: max(0, capped + :rand.uniform(spread * 2 + 1) - spread - 1),
      else: capped
  end

  defp run(fun, attempt, opts) do
    case fun.() do
      {:error, reason} = error -> retry_or_return(error, reason, fun, attempt, opts)
      result -> result
    end
  end

  defp retry_or_return(error, reason, fun, attempt, opts) do
    cond do
      not opts[:retriable?].(reason) ->
        error

      attempt >= opts[:max_attempts] ->
        Logger.warning("Retry attempts exhausted",
          attempts: attempt,
          error: LogFormat.reason(reason)
        )

        error

      true ->
        delay = delay(attempt, opts)

        Logger.info("Retrying after error",
          attempt: attempt,
          max_attempts: opts[:max_attempts],
          delay_ms: delay,
          error: LogFormat.reason(reason)
        )

        Process.sleep(delay)
        run(fun, attempt + 1, opts)
    end
  end
end
