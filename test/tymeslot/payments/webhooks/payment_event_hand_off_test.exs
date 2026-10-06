defmodule Tymeslot.Payments.Webhooks.PaymentEventHandOffTest do
  @moduledoc """
  The durable hand-off of payment events to the configured
  `:payment_event_handler`. Core answers Stripe only after the handler has
  taken the event, and a handler failure fails the delivery so Stripe sends
  it again.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :payments
  @moduletag :webhooks

  alias Tymeslot.Payments.PubSub
  alias Tymeslot.Payments.Webhooks.{Idempotency, IdempotencyCache, SubscriptionHandler}
  alias Tymeslot.Payments.Webhooks.WebhookProcessor

  defmodule RecordingHandler do
    @spec handle_payment_event(map()) :: :ok
    def handle_payment_event(event) do
      send(Application.fetch_env!(:tymeslot, :hand_off_test_pid), {:handed_off, event})
      :ok
    end
  end

  defmodule FailingHandler do
    @spec handle_payment_event(map()) :: {:error, term()}
    def handle_payment_event(_event), do: {:error, :enqueue_failed}
  end

  setup do
    original = Application.get_env(:tymeslot, :payment_event_handler)
    Application.put_env(:tymeslot, :hand_off_test_pid, self())

    on_exit(fn ->
      Application.delete_env(:tymeslot, :hand_off_test_pid)

      if original,
        do: Application.put_env(:tymeslot, :payment_event_handler, original),
        else: Application.delete_env(:tymeslot, :payment_event_handler)
    end)

    :ok
  end

  defp subscription_updated_event(id) do
    %{
      "id" => id,
      "type" => "customer.subscription.updated",
      "data" => %{"object" => %{"id" => "sub_hand_off", "status" => "active"}}
    }
  end

  describe "with a handler configured" do
    test "the handler receives a webhook's subscription event" do
      Application.put_env(:tymeslot, :payment_event_handler, RecordingHandler)

      assert {:ok, :event_processed} =
               SubscriptionHandler.process(
                 %{type: "customer.subscription.updated"},
                 %{"id" => "sub_hand_off", "status" => "active"}
               )

      assert_received {:handed_off,
                       %{event: :subscription_updated, subscription_id: "sub_hand_off"}}
    end

    test "a handler failure fails the delivery, so Stripe redelivers it" do
      Application.put_env(:tymeslot, :payment_event_handler, FailingHandler)

      assert {:error, :retry_later} =
               Idempotency.with_idempotency(
                 "evt_hand_off_fails",
                 "customer.subscription.updated",
                 fn ->
                   WebhookProcessor.process_event(
                     subscription_updated_event("evt_hand_off_fails")
                   )
                 end
               )

      assert IdempotencyCache.check_idempotency("evt_hand_off_fails") == {:ok, :not_processed}
    end

    test "a dispute, refund or trial event is handed off with its Stripe event id" do
      Application.put_env(:tymeslot, :payment_event_handler, RecordingHandler)

      assert :ok = PubSub.hand_off_payment_event(:trial_will_end, %{event_id: "evt_trial"})

      assert_received {:handed_off, %{event: :trial_will_end, data: %{event_id: "evt_trial"}}}
    end
  end

  describe "without a handler" do
    test "the event is accepted and goes nowhere" do
      Application.delete_env(:tymeslot, :payment_event_handler)

      assert :ok = PubSub.hand_off_payment_event(:trial_will_end, %{event_id: "evt_plain"})

      refute_received {:handed_off, _event}
    end
  end
end
