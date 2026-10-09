defmodule Tymeslot.Payments do
  @moduledoc """
  Main entry point for payment operations.
  Provides a high-level interface for executing payment transactions.
  """

  require Logger

  alias Tymeslot.Payments.PaymentTransactionSchema, as: PaymentTransaction

  alias Tymeslot.Payments.{
    CustomerLookup,
    DatabaseOperations,
    PaymentQueries,
    SubscriptionFlow,
    SubscriptionInvoice,
    SubscriptionInvoices
  }

  alias Tymeslot.Payments.Webhooks.Ingress

  @type transaction :: PaymentTransaction.t()
  @type stripe_id :: String.t()

  @doc """
  Verifies and processes one Stripe webhook delivery to `endpoint`
  (`:platform` or `:connect`), reading that endpoint's signing secret from
  configuration. See `Tymeslot.Payments.Webhooks.Ingress.process/3` for the
  outcomes.
  """
  @spec process_webhook(Ingress.endpoint(), binary(), String.t() | nil) :: Ingress.result()
  defdelegate process_webhook(endpoint, raw_body, signature), to: Ingress, as: :process

  @doc """
  Processes a failed payment.

  ## Parameters
    * stripe_id - The Stripe session ID

  ## Returns
    * `{:ok, :payment_failed}` - If the payment failure is recorded successfully
    * `{:error, reason}` - If recording the payment failure fails
  """
  @spec process_failed_payment(stripe_id()) ::
          {:ok, :payment_failed | :transaction_not_found} | {:error, String.t()}
  def process_failed_payment(stripe_id) do
    Logger.info("Processing failed payment", stripe_id: stripe_id)
    DatabaseOperations.process_failed_payment(stripe_id)
  end

  @doc """
  Lists a user's platform subscription invoices, newest first.

  Each entry carries the Stripe-hosted invoice page and PDF, so callers can
  link a customer straight to their VAT document instead of routing them
  through the billing portal. Covers subscription invoices only — Connect
  direct-charge booking invoices are not captured; see
  `SubscriptionInvoiceSchema`.

  ## Parameters
    * user_id - The ID of the user whose invoices to list
    * limit - Maximum number of invoices to return (defaults to
      `SubscriptionInvoiceQueries`'s default when omitted)
  """
  @spec list_subscription_invoices(pos_integer()) :: [SubscriptionInvoice.t()]
  def list_subscription_invoices(user_id) do
    SubscriptionInvoices.list(user_id)
  end

  @spec list_subscription_invoices(pos_integer(), pos_integer()) :: [SubscriptionInvoice.t()]
  def list_subscription_invoices(user_id, limit) do
    SubscriptionInvoices.list(user_id, limit)
  end

  @doc """
  Initiates a subscription with the provided payment details.

  This function creates a Stripe checkout session for recurring payments.
  The calling application is responsible for plan validation and providing
  the concrete payment details (stripe_price_id, amount, product_identifier).

  ## Parameters
    * stripe_price_id - The Stripe price ID for the subscription
    * product_identifier - Generic identifier for what is being purchased (plan name, etc.)
    * amount - The subscription amount in cents (for transaction tracking)
    * user_id - The ID of the user purchasing the subscription
    * email - The user's email address
    * success_url - URL to redirect to after successful subscription (required)
    * cancel_url - URL to redirect to if subscription is cancelled (required)
    * metadata - Additional metadata for the subscription (app-specific data)

  ## Returns
    * `{:ok, %{checkout_url: url}}` - URL for the Stripe checkout session
    * `{:error, reason}` - If the subscription creation fails
  """
  @spec initiate_subscription(
          stripe_price_id :: String.t(),
          product_identifier :: String.t(),
          amount :: pos_integer(),
          user_id :: pos_integer(),
          email :: String.t(),
          urls :: %{success: String.t(), cancel: String.t()},
          metadata :: map()
        ) :: {:ok, %{checkout_url: String.t()}} | {:error, term()}
  def initiate_subscription(
        stripe_price_id,
        product_identifier,
        amount,
        user_id,
        email,
        urls,
        metadata \\ %{}
      ) do
    SubscriptionFlow.initiate_subscription(
      stripe_price_id,
      product_identifier,
      amount,
      user_id,
      email,
      urls,
      metadata
    )
  end

  @doc """
  Reads a user id out of Stripe metadata, which carries it as a string.

  Returns `nil` for anything that is not a whole number, so a malformed or
  absent value never becomes a wrong user.
  """
  @spec parse_user_id(any()) :: integer() | nil
  defdelegate parse_user_id(id), to: CustomerLookup

  @doc """
  Records a checkout session's outcome against its transaction row, attaching
  the subscription it produced.
  """
  @spec update_transaction_for_subscription(String.t(), String.t(), String.t(), map()) ::
          {:ok, transaction()} | {:error, term()}
  defdelegate update_transaction_for_subscription(
                checkout_session_id,
                subscription_id,
                status,
                metadata
              ),
              to: DatabaseOperations

  @doc """
  Lists every distinct Stripe customer id recorded on the user's payment
  transactions, including customers created by checkouts that were never
  completed.
  """
  @spec stripe_customer_ids_for_user(integer()) :: [String.t()]
  defdelegate stripe_customer_ids_for_user(user_id), to: PaymentQueries
end
