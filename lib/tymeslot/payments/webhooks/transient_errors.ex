defmodule Tymeslot.Payments.Webhooks.TransientErrors do
  @moduledoc """
  Tells a transient failure (one a later webhook delivery can get past)
  from a deterministic one, by the exception's struct rather than its
  message: a lost or exhausted database connection, a Postgres error that
  reports contention rather than bad data, and a Stripe network failure,
  rate limit or server error.
  """

  # Postgres conditions that say "try again", not "this data is wrong".
  @transient_postgres_codes [
    :serialization_failure,
    :deadlock_detected,
    :lock_not_available,
    :query_canceled,
    :too_many_connections,
    :admin_shutdown,
    :crash_shutdown,
    :cannot_connect_now
  ]

  @doc """
  Returns `true` when `exception` is a failure a retry can get past.
  """
  @spec transient?(struct()) :: boolean()
  def transient?(%DBConnection.ConnectionError{}), do: true

  def transient?(%Postgrex.Error{postgres: %{code: code}}),
    do: code in @transient_postgres_codes

  def transient?(%Stripe.Error{source: :network}), do: true

  def transient?(%Stripe.Error{source: :stripe, extra: %{http_status: status}})
      when status == 429 or status >= 500,
      do: true

  def transient?(_exception), do: false
end
