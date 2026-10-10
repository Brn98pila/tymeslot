defmodule Tymeslot.Workers.EmailWorkerAmbiguousTimeoutTest do
  @moduledoc """
  A send that timed out after the message may have been handed over is
  retried once, and never again: the job records the retry, and its next run
  assumes such a send delivered. A copy kept as sent, or assumed sent, never
  goes out again. Runs the real email service through a failing adapter, so
  every attempt counted reached the provider.
  """

  # async: false: the mailer adapter, its error and the email service are
  # global configuration, and the email circuit breaker is shared.
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  import ExUnit.CaptureLog
  import Tymeslot.ConfigTestHelpers

  @moduletag :emails

  alias Tymeslot.Infrastructure.CircuitBreaker
  alias Tymeslot.Infrastructure.CircuitBreakerSupervisor
  alias Tymeslot.Test.FailingMailerAdapter
  alias Tymeslot.Workers.EmailWorker

  setup do
    setup_config(:tymeslot, Tymeslot.Mailer, adapter: FailingMailerAdapter)
    setup_config(:tymeslot, :test_delivery_error, :timeout)
    setup_config(:tymeslot, :test_delivery_attempts_to, self())
    setup_config(:tymeslot, :email_service_module, Tymeslot.Emails.EmailService)

    breaker = CircuitBreakerSupervisor.email_breaker_name()
    CircuitBreaker.reset(breaker)
    on_exit(fn -> CircuitBreaker.reset(breaker) end)
    :ok
  end

  test "a single email is retried once after an ambiguous timeout, then assumed sent" do
    user = insert(:user)
    job = insert_job(%{"action" => "send_no_password_to_reset", "user_id" => user.id})

    assert {:error, _reason} = quietly(fn -> run(job) end)
    assert_received {:delivery_attempt, _to}

    assert :ok = quietly(fn -> run(job) end)
    assert_received {:delivery_attempt, _to}
    refute_received {:delivery_attempt, _more}
  end

  test "each claimed copy is retried once, and never sent again once assumed sent" do
    meeting = insert(:meeting, status: "cancelled")
    job = insert_job(%{"action" => "send_cancellation_emails", "meeting_id" => meeting.id})

    assert {:error, _reason} = quietly(fn -> run(job) end)
    assert_received {:delivery_attempt, _organizer}
    assert_received {:delivery_attempt, _attendee}

    assert :ok = quietly(fn -> run(job) end)
    assert_received {:delivery_attempt, _organizer}
    assert_received {:delivery_attempt, _attendee}

    # Whatever happens after, the copies assumed sent are claimed.
    setup_config(:tymeslot, :test_delivery_error, :econnrefused)
    assert :ok = quietly(fn -> run(job) end)
    refute_received {:delivery_attempt, _more}
  end

  # Only an ambiguous timeout spends the one retry; an ordinary failure
  # retries as before, and a later ambiguous timeout still gets its retry.
  test "an ordinary failure does not spend the retry an ambiguous timeout gets" do
    user = insert(:user)
    job = insert_job(%{"action" => "send_no_password_to_reset", "user_id" => user.id})

    setup_config(:tymeslot, :test_delivery_error, :econnrefused)
    assert {:error, _reason} = quietly(fn -> run(job) end)

    setup_config(:tymeslot, :test_delivery_error, :timeout)
    assert {:error, _reason} = quietly(fn -> run(job) end)
    assert :ok = quietly(fn -> run(job) end)
  end

  defp insert_job(args) do
    {:ok, job} = args |> EmailWorker.new() |> Oban.insert()
    job
  end

  # Each timeout counts against the email circuit breaker; a run here stands
  # for a retry minutes later, once it has recovered.
  defp run(job) do
    CircuitBreaker.reset(CircuitBreakerSupervisor.email_breaker_name())
    EmailWorker.perform(%{job | attempt: job.attempt + 1})
  end

  defp quietly(fun) do
    capture_log(fn -> send(self(), {:result, fun.()}) end)
    assert_received {:result, result}
    result
  end
end
