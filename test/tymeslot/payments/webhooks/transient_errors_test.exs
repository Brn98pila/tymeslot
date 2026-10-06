defmodule Tymeslot.Payments.Webhooks.TransientErrorsTest do
  use ExUnit.Case, async: true

  @moduletag :payments
  @moduletag :webhooks
  @moduletag :unit

  alias Tymeslot.Payments.Webhooks.TransientErrors

  test "a lost database connection is transient" do
    assert TransientErrors.transient?(%DBConnection.ConnectionError{message: "closed"})
  end

  test "Postgres contention is transient, bad data is not" do
    assert TransientErrors.transient?(%Postgrex.Error{postgres: %{code: :deadlock_detected}})
    refute TransientErrors.transient?(%Postgrex.Error{postgres: %{code: :unique_violation}})
  end

  test "a Stripe network failure, rate limit or server error is transient" do
    assert TransientErrors.transient?(%Stripe.Error{source: :network, code: :x, message: "x"})

    assert TransientErrors.transient?(%Stripe.Error{
             source: :stripe,
             code: :x,
             message: "x",
             extra: %{http_status: 503}
           })

    assert TransientErrors.transient?(%Stripe.Error{
             source: :stripe,
             code: :x,
             message: "x",
             extra: %{http_status: 429}
           })
  end

  test "a Stripe client error and any other exception are not" do
    refute TransientErrors.transient?(%Stripe.Error{
             source: :stripe,
             code: :x,
             message: "x",
             extra: %{http_status: 400}
           })

    refute TransientErrors.transient?(%RuntimeError{message: "bug"})
  end
end
