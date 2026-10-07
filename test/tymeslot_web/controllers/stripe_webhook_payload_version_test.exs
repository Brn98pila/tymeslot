defmodule TymeslotWeb.StripeWebhookPayloadVersionTest do
  @moduledoc """
  Both Stripe endpoints read events in the shape Stripe sends them.

  An endpoint renders its events at the API version it was created with
  (`2020-08-27` for both of ours), whatever version the client library
  pins. Each test here signs a body of that version, posts it to the real
  endpoint and lets the real signature check decode it, so a field the
  newer version dropped or moved still reaches the handler that reads it.
  """

  # async: false: the Stripe provider, adapter and secrets are global config.
  use TymeslotWeb.ConnCase, async: false

  @moduletag :payments
  @moduletag :webhooks
  @moduletag :controllers
  @moduletag :integration

  import Tymeslot.Test.PaymentEventCapture
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.MeetingPayments.StripeAdapter
  alias Tymeslot.Payments.PaymentTransactionSchema
  alias Tymeslot.Payments.SubscriptionInvoiceQueries
  alias Tymeslot.Repo
  alias Tymeslot.StripeWebhookFixtures

  @platform_secret "whsec_platform_2020"
  @connect_secret "whsec_connect_2020"

  defp post_signed(conn, path, body, signature) do
    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("stripe-signature", signature)
    |> post(path, body)
  end

  describe "platform endpoint" do
    setup do
      with_config(:tymeslot,
        skip_webhook_verification: false,
        stripe_provider: Tymeslot.Payments.Stripe,
        stripe_webhook_secret: @platform_secret,
        repo: Repo,
        subscription_schema: PaymentTransactionSchema
      )

      capture_payment_events()
    end

    test "a subscription update hands on the billing period at the top of the subscription",
         %{conn: conn} do
      body = StripeWebhookFixtures.body("customer.subscription.updated")
      signature = StripeWebhookFixtures.signature(body, @platform_secret)

      assert conn |> post_signed("/webhooks/stripe", body, signature) |> response(200) == ""

      assert_received %{
        event: :subscription_updated,
        subscription_id: "sub_1SfixtureSubscription",
        subscription_data: subscription
      }

      assert subscription["current_period_start"] == 1_759_752_000
      assert subscription["current_period_end"] == 1_762_430_400
    end

    test "a refund names the subscription its charge's invoice paid for", %{conn: conn} do
      {:ok, _invoice} =
        SubscriptionInvoiceQueries.upsert(%{
          stripe_invoice_id: "in_1SfixtureRenewal",
          subscription_id: "sub_paid_for"
        })

      body = StripeWebhookFixtures.body("charge.refunded")
      signature = StripeWebhookFixtures.signature(body, @platform_secret)

      assert conn |> post_signed("/webhooks/stripe", body, signature) |> response(200) == ""

      assert_received %{
        event: :charge_refunded,
        data: %{
          invoice_id: "in_1SfixtureRenewal",
          subscription_id: "sub_paid_for",
          should_revoke: true
        }
      }
    end

    test "a body altered after signing is still rejected", %{conn: conn} do
      body = StripeWebhookFixtures.body("charge.refunded")
      signature = StripeWebhookFixtures.signature(body, @platform_secret)
      tampered = String.replace(body, "in_1SfixtureRenewal", "in_1SfixtureForged")

      assert conn |> post_signed("/webhooks/stripe", tampered, signature) |> response(400) ==
               ""

      refute_received %{event: :charge_refunded}
    end
  end

  describe "Connect endpoint" do
    setup do
      with_config(:tymeslot,
        stripe_adapter: StripeAdapter.Stripity,
        stripe_connect_webhook_secret: @connect_secret
      )

      :ok
    end

    test "verification hands the event on exactly as Stripe sent it" do
      body = StripeWebhookFixtures.body("charge.refunded")
      signature = StripeWebhookFixtures.signature(body, @connect_secret)

      assert {:ok, event} =
               StripeAdapter.construct_webhook_event(body, signature, @connect_secret)

      assert event == Jason.decode!(body)
      assert event["data"]["object"]["invoice"] == "in_1SfixtureRenewal"
    end

    test "a dispute before the charge id is known finds the booking by its payment intent",
         %{conn: conn} do
      payment =
        insert(:booking_payment,
          stripe_account_id: "acct_fixtureHost",
          stripe_payment_intent_id: "pi_1SfixtureBookingIntent",
          stripe_charge_id: nil,
          status: "paid"
        )

      body = StripeWebhookFixtures.body("charge.dispute.created")
      signature = StripeWebhookFixtures.signature(body, @connect_secret)

      assert conn |> post_signed("/webhooks/stripe/connect", body, signature) |> response(200) ==
               ""

      reloaded = Repo.reload!(payment)
      assert reloaded.status == "disputed"
      assert reloaded.last_event_id == "evt_1SfixtureDisputeCreated"
    end

    test "a body altered after signing is still rejected", %{conn: conn} do
      payment =
        insert(:booking_payment,
          stripe_account_id: "acct_fixtureHost",
          stripe_payment_intent_id: "pi_1SfixtureBookingIntent",
          status: "paid"
        )

      body = StripeWebhookFixtures.body("charge.dispute.created")
      signature = StripeWebhookFixtures.signature(body, @connect_secret)
      tampered = String.replace(body, "fraudulent", "duplicate")

      assert conn
             |> post_signed("/webhooks/stripe/connect", tampered, signature)
             |> response(400) == ""

      assert Repo.reload!(payment).status == "paid"
    end
  end
end
