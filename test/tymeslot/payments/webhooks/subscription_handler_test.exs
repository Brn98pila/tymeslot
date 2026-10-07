defmodule Tymeslot.Payments.Webhooks.SubscriptionHandlerTest do
  use Tymeslot.DataCase, async: false
  @moduletag :payments

  import Tymeslot.Test.PaymentEventCapture

  alias Tymeslot.Payments.Webhooks.SubscriptionHandler
  alias Tymeslot.Payments.Webhooks.WebhookProcessor

  describe "can_handle?/1" do
    test "returns true for supported subscription events" do
      assert SubscriptionHandler.can_handle?("customer.subscription.created")
      assert SubscriptionHandler.can_handle?("customer.subscription.updated")
      assert SubscriptionHandler.can_handle?("customer.subscription.deleted")
    end

    test "returns false for unsupported events" do
      refute SubscriptionHandler.can_handle?("customer.created")
    end
  end

  describe "validate/1" do
    test "returns :ok for valid subscription" do
      assert SubscriptionHandler.validate(%{"id" => "sub_123"}) == :ok
    end

    test "returns error for missing or empty id" do
      assert {:error, :missing_field, _reason} = SubscriptionHandler.validate(%{})
      assert {:error, :missing_field, _reason} = SubscriptionHandler.validate(%{"id" => ""})
    end
  end

  describe "process/2" do
    test "hands off subscription events" do
      capture_payment_events()

      subscription = %{"id" => "sub_123", "status" => "active"}
      event = %{"type" => "customer.subscription.created"}

      assert {:ok, :event_processed} = SubscriptionHandler.process(event, subscription)

      assert_receive %{
        event: :subscription_created,
        subscription_id: "sub_123",
        subscription_data: ^subscription
      }
    end

    # The receiver orders events by Stripe's creation time and deduplicates
    # them by id, so both must travel with the subscription.
    test "carries the Stripe event's id and creation time" do
      capture_payment_events()

      subscription = %{"id" => "sub_ordered", "status" => "active"}

      event = %{
        "id" => "evt_ordered",
        "created" => 1_700_000_123,
        "type" => "customer.subscription.updated"
      }

      assert {:ok, :event_processed} = SubscriptionHandler.process(event, subscription)

      assert_receive %{
        subscription_id: "sub_ordered",
        event_id: "evt_ordered",
        event_created: 1_700_000_123
      }
    end

    test "handles unknown subscription events with generic name" do
      capture_payment_events()

      subscription = %{"id" => "sub_123"}
      event = %{"type" => "customer.subscription.something_else"}

      assert {:ok, :event_processed} = SubscriptionHandler.process(event, subscription)

      assert_receive %{
        event: :subscription_event,
        subscription_id: "sub_123"
      }
    end
  end

  describe "through the webhook processor" do
    # The processor hands Stripe's string-keyed event on unchanged, so the
    # event name must come from its "type" key.
    test "names the hand-off after the event's type" do
      capture_payment_events()

      event = %{
        "id" => "evt_through_processor",
        "type" => "customer.subscription.deleted",
        "created" => 1_700_000_000,
        "data" => %{"object" => %{"id" => "sub_through_processor", "status" => "canceled"}}
      }

      assert {:ok, :event_processed} = WebhookProcessor.process_event(event)

      assert_receive %{
        event: :subscription_deleted,
        subscription_id: "sub_through_processor",
        event_id: "evt_through_processor"
      }
    end
  end
end
