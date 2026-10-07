defmodule Tymeslot.Payments.Webhooks.SubscriptionHandler do
  @moduledoc """
  Handler for customer.subscription.* webhook events.
  """
  use Tymeslot.Payments.Behaviours.WebhookHandler

  require Logger
  alias Tymeslot.Payments.PubSub

  @impl Tymeslot.Payments.Behaviours.WebhookHandler
  def can_handle?(event_type) do
    event_type in [
      "customer.subscription.created",
      "customer.subscription.updated",
      "customer.subscription.deleted"
    ]
  end

  @impl Tymeslot.Payments.Behaviours.WebhookHandler
  def validate(subscription) do
    validate_id(subscription)
  end

  defp validate_id(subscription) do
    case Map.get(subscription, "id") do
      nil -> {:error, :missing_field, "Subscription ID missing"}
      "" -> {:error, :missing_field, "Subscription ID empty"}
      _id -> :ok
    end
  end

  @impl Tymeslot.Payments.Behaviours.WebhookHandler
  def process(event, subscription) do
    event_type = event["type"]
    subscription_id = subscription["id"]

    Logger.info("Processing subscription event",
      event_type: event_type,
      subscription_id: subscription_id
    )

    # The Stripe event's id and creation time let the receiver deduplicate
    # redeliveries and ignore an event older than one it has already applied.
    case PubSub.hand_off_subscription_event(%{
           event: normalize_event_name(event_type),
           subscription_id: subscription_id,
           subscription_data: subscription,
           event_id: event["id"],
           event_created: event["created"]
         }) do
      :ok -> {:ok, :event_processed}
      {:error, _reason} -> {:error, :retry_later, "Subscription event hand-off failed"}
    end
  end

  defp normalize_event_name("customer.subscription.created"), do: :subscription_created
  defp normalize_event_name("customer.subscription.updated"), do: :subscription_updated
  defp normalize_event_name("customer.subscription.deleted"), do: :subscription_deleted
  defp normalize_event_name(_other), do: :subscription_event
end
