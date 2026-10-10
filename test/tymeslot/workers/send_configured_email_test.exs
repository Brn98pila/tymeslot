defmodule Tymeslot.Workers.SendConfiguredEmailTest do
  @moduledoc """
  An email a payment webhook enqueues waits out an open mail circuit (the
  job snoozes, spending no attempt) and goes out once it closes, instead of
  being dropped as it was when the webhook sent it inline.
  """

  # async: false: the template, the mailer adapter and the email circuit
  # breaker are global.
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  import ExUnit.CaptureLog
  import Tymeslot.ConfigTestHelpers

  @moduletag :payments
  @moduletag :emails

  alias Swoosh.Email
  alias Tymeslot.Emails.Delivery
  alias Tymeslot.Infrastructure.CircuitBreaker
  alias Tymeslot.Infrastructure.CircuitBreakerSupervisor
  alias Tymeslot.Test.FailingMailerAdapter
  alias Tymeslot.Workers.SendConfiguredEmail

  defmodule Template do
    @moduledoc false
    @spec notice(term(), map()) :: Email.t()
    def notice(%{email: address}, %{amount: amount}), do: notice_email(address, amount)

    def notice(address, %{amount: amount}) when is_binary(address),
      do: notice_email(address, amount)

    defp notice_email(address, amount) do
      Email.new(
        to: address,
        from: "noreply@example.com",
        subject: "Notice #{amount}",
        text_body: "Notice.",
        html_body: "<p>Notice.</p>"
      )
    end
  end

  setup do
    setup_config(:tymeslot, :test_configured_notice_template, Template)
    Application.put_env(:swoosh, :shared_test_process, self())
    breaker = CircuitBreakerSupervisor.email_breaker_name()
    CircuitBreaker.reset(breaker)

    on_exit(fn ->
      Application.delete_env(:swoosh, :shared_test_process)
      CircuitBreaker.reset(breaker)
    end)

    %{breaker: breaker}
  end

  test "waits out an open mail circuit, then sends the email once", %{breaker: breaker} do
    user = insert(:user)
    insert(:profile, user: user)

    assert :ok =
             SendConfiguredEmail.enqueue(
               :test_configured_notice_template,
               :notice,
               {:user, user.id},
               [%{amount: 42}]
             )

    [job] = all_enqueued(worker: SendConfiguredEmail)
    open_breaker(breaker)

    assert {:snooze, _seconds} = quietly(fn -> run_attempt(job) end)
    refute_received {:email, _sent}

    CircuitBreaker.reset(breaker)
    assert :ok = run_attempt(job)
    assert_received {:email, %{subject: "Notice 42"}}

    # Claimed once sent: a rescued run sends nothing more.
    assert :ok = run_attempt(job)
    refute_received {:email, _again}
  end

  test "sends to an address, as the dispute alerts do" do
    :ok =
      SendConfiguredEmail.enqueue(
        :test_configured_notice_template,
        :notice,
        {:address, "ops@example.com"},
        [%{amount: 7}]
      )

    assert %{success: 1} = Oban.drain_queue(queue: :emails)
    assert_received {:email, %{subject: "Notice 7", to: [{"", "ops@example.com"}]}}
  end

  test "an unconfigured template enqueues nothing" do
    assert :ok = SendConfiguredEmail.enqueue(:no_such_template, :notice, {:user, 1}, [])
    assert all_enqueued(worker: SendConfiguredEmail) == []
  end

  defp open_breaker(breaker) do
    adapter = Application.get_env(:tymeslot, Tymeslot.Mailer)
    setup_config(:tymeslot, Tymeslot.Mailer, adapter: FailingMailerAdapter)
    threshold = CircuitBreaker.status(breaker).config.failure_threshold

    quietly(fn ->
      for _attempt <- 1..threshold do
        Delivery.deliver(Email.new(to: "x@example.com", subject: "s", text_body: "t"))
      end
    end)

    Application.put_env(:tymeslot, Tymeslot.Mailer, adapter)
    :sys.get_state(breaker)
    assert CircuitBreaker.status(breaker).status == :open
  end

  defp run_attempt(job), do: SendConfiguredEmail.perform(%{job | attempt: job.attempt + 1})

  defp quietly(fun) do
    capture_log(fn -> send(self(), {:result, fun.()}) end)
    assert_received {:result, result}
    result
  end
end
