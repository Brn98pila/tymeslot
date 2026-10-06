defmodule Tymeslot.Payments.PaymentModulesTest do
  # PubSub tests need sequential execution
  use Tymeslot.DataCase, async: false
  @moduletag :payments

  import Tymeslot.Test.PaymentEventCapture
  alias Tymeslot.Payments.{ErrorHandler, PubSub}
  alias Tymeslot.Payments.Errors.WebhookError.ProcessingError
  alias Tymeslot.Payments.Errors.WebhookError.SignatureError
  alias Tymeslot.Payments.Errors.WebhookError.ValidationError
  alias Tymeslot.Test.LogCapture

  describe "ErrorHandler" do
    setup do
      LogCapture.attach()
      :ok
    end

    test "handle_payment_error logs the stripe id, user and error at :error level" do
      assert {:ok, :error_handled} =
               ErrorHandler.handle_payment_error("stripe_123", :card_declined, 1)

      assert_receive {:captured_log,
                      %{
                        level: :error,
                        msg: {:string, message},
                        meta: %{stripe_id: _stripe_id} = meta
                      }}

      assert IO.iodata_to_binary(message) == "Payment error"
      assert meta.stripe_id == "stripe_123"
      assert meta.user_id == 1
      assert meta.error == ":card_declined"
    end

    test "handle_subscription_error logs the subscription id, user and error at :error level" do
      assert {:ok, :error_handled} =
               ErrorHandler.handle_subscription_error("sub_123", :payment_failed, 1)

      assert_receive {:captured_log,
                      %{
                        level: :error,
                        msg: {:string, message},
                        meta: %{subscription_id: _subscription_id} = meta
                      }}

      assert IO.iodata_to_binary(message) == "Subscription error"
      assert meta.subscription_id == "sub_123"
      assert meta.user_id == 1
      assert meta.error == ":payment_failed"
    end
  end

  describe "PubSub" do
    setup :capture_payment_events

    test "hand_off_payment_event hands the event to the payment-event handler" do
      assert :ok =
               PubSub.hand_off_payment_event(:charge_succeeded, %{
                 charge_id: "ch_123",
                 user_id: 42
               })

      assert_received %{event: :charge_succeeded, data: %{charge_id: "ch_123", user_id: 42}}
    end
  end

  describe "WebhookError" do
    test "SignatureError can be created" do
      error = %SignatureError{message: "test", reason: :invalid}
      assert error.message == "test"
      assert SignatureError.message(error) == "test"
    end

    test "ValidationError can be created" do
      error = %ValidationError{message: "test", reason: :invalid}
      assert error.message == "test"
      assert ValidationError.message(error) == "test"
    end

    test "ProcessingError can be created" do
      error = %ProcessingError{message: "test", reason: :failed}
      assert error.message == "test"
      assert ProcessingError.message(error) == "test"
    end
  end
end
