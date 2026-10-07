defmodule Tymeslot.Payments.Webhooks.WebhookProcessorTest do
  use ExUnit.Case, async: false
  @moduletag :payments

  import ExUnit.CaptureLog
  import Mox

  alias Tymeslot.Payments.Webhooks.WebhookProcessor
  alias Tymeslot.Test.LogCapture

  setup :set_mox_from_context
  setup :verify_on_exit!

  defmodule TestAdminAlerts do
    @spec send_alert(atom(), map()) :: :ok
    def send_alert(event_type, payload) do
      pid = Application.get_env(:tymeslot, :admin_alerts_test_pid)
      send(pid, {:send_alert, event_type, payload})
      :ok
    end
  end

  describe "process_event/1 unhandled events" do
    test "sends sanitized alert payloads for unhandled events" do
      original_alerts = Application.get_env(:tymeslot, :admin_alerts_impl)
      original_pid = Application.get_env(:tymeslot, :admin_alerts_test_pid)

      Application.put_env(:tymeslot, :admin_alerts_impl, TestAdminAlerts)
      Application.put_env(:tymeslot, :admin_alerts_test_pid, self())

      on_exit(fn ->
        Application.put_env(:tymeslot, :admin_alerts_impl, original_alerts)
        Application.put_env(:tymeslot, :admin_alerts_test_pid, original_pid)
      end)

      event = %{
        "id" => "evt_999",
        "type" => "charge.unknown",
        "created" => 1_700_000_000,
        "livemode" => false,
        "data" => %{
          "object" => %{
            "id" => "obj_123",
            "object" => "charge",
            "metadata" => %{"email" => "sensitive@example.com", "note" => "sensitive-note"}
          }
        }
      }

      assert {:ok, :unhandled_event} =
               LogCapture.with_capture([logger_level: :debug], fn ->
                 WebhookProcessor.process_event(event)
               end)

      # The object's metadata carries customer details and is never logged.
      logs = Enum.map(LogCapture.drain(), &LogCapture.dump/1)
      assert Enum.any?(logs, &(&1 =~ "Received unhandled Stripe event"))
      refute Enum.any?(logs, &(&1 =~ "sensitive"))

      assert_receive {:send_alert, :unhandled_webhook, payload}
      assert payload.event_id == "evt_999"
      assert payload.event_type == "charge.unknown"
      assert payload.object_id == "obj_123"
      assert payload.object_type == "charge"
      refute Map.has_key?(payload, :event)
      refute Map.has_key?(payload, :object)
    end

    test "acknowledges benign application_fee events without alerting" do
      original_alerts = Application.get_env(:tymeslot, :admin_alerts_impl)
      original_pid = Application.get_env(:tymeslot, :admin_alerts_test_pid)

      Application.put_env(:tymeslot, :admin_alerts_impl, TestAdminAlerts)
      Application.put_env(:tymeslot, :admin_alerts_test_pid, self())

      on_exit(fn ->
        Application.put_env(:tymeslot, :admin_alerts_impl, original_alerts)
        Application.put_env(:tymeslot, :admin_alerts_test_pid, original_pid)
      end)

      event = %{
        "id" => "evt_fee_1",
        "type" => "application_fee.created",
        "created" => 1_700_000_000,
        "livemode" => false,
        "data" => %{
          "object" => %{"id" => "fee_123", "object" => "application_fee"}
        }
      }

      assert {:ok, :ignored_event} = WebhookProcessor.process_event(event)

      refute_receive {:send_alert, :unhandled_webhook, _payload}
    end
  end

  describe "process_event/1 retry behavior" do
    test "returns retry_later for Stripe outages" do
      original_provider = Application.get_env(:tymeslot, :stripe_provider)
      Application.put_env(:tymeslot, :stripe_provider, Tymeslot.Payments.StripeMock)

      on_exit(fn ->
        Application.put_env(:tymeslot, :stripe_provider, original_provider)
      end)

      # The handler expects a map with "customer" key or atom :customer
      expect(Tymeslot.Payments.StripeMock, :get_charge, fn _charge_id ->
        {:error, %{message: "Stripe API is down"}}
      end)

      object = %{
        "id" => "dp_outage",
        "charge" => "ch_outage",
        "amount" => 1000,
        "status" => "needs_response",
        "reason" => "fraudulent"
      }

      event = %{
        "id" => "evt_outage",
        "type" => "charge.dispute.created",
        "data" => %{
          "object" => object
        }
      }

      assert {:error, :retry_later, _error_reason} = WebhookProcessor.process_event(event)
    end
  end

  # A handler error is retried unless it is known to be permanent: marking a
  # transient failure processed answers Stripe 200 and the event is never
  # redelivered, so a paid checkout whose subscription write hit a database
  # timeout would never grant Pro.
  describe "process_event/1 retry default" do
    defmodule TimingOutManager do
      @spec handle_checkout_completed(map()) :: {:error, term()}
      def handle_checkout_completed(_session), do: {:error, :database_timeout}
    end

    defmodule DisconnectedManager do
      @spec handle_checkout_completed(map()) :: no_return()
      def handle_checkout_completed(_session),
        do: raise(DBConnection.ConnectionError, "connection not available")
    end

    defmodule BrokenManager do
      @spec handle_checkout_completed(map()) :: no_return()
      def handle_checkout_completed(_session), do: raise("a bug")
    end

    setup do
      original = Application.get_env(:tymeslot, :subscription_manager)
      on_exit(fn -> Application.put_env(:tymeslot, :subscription_manager, original) end)
      :ok
    end

    defp checkout_completed_event do
      %{
        "id" => "evt_checkout_retry",
        "type" => "checkout.session.completed",
        "data" => %{"object" => %{"id" => "cs_retry", "mode" => "subscription"}}
      }
    end

    test "retries a checkout whose subscription manager failed" do
      Application.put_env(:tymeslot, :subscription_manager, TimingOutManager)

      capture_log(fn ->
        assert {:error, :retry_later, _message} =
                 WebhookProcessor.process_event(checkout_completed_event())
      end)
    end

    test "retries a handler that raised a transient exception" do
      Application.put_env(:tymeslot, :subscription_manager, DisconnectedManager)

      capture_log(fn ->
        assert {:error, :retry_later, _message} =
                 WebhookProcessor.process_event(checkout_completed_event())
      end)
    end

    test "does not retry a handler that raised a bug" do
      Application.put_env(:tymeslot, :subscription_manager, BrokenManager)

      capture_log(fn ->
        assert {:error, %{reason: :handler_exception}, nil} =
                 WebhookProcessor.process_event(checkout_completed_event())
      end)
    end

    test "does not retry an error the handler marks as permanent" do
      Application.delete_env(:tymeslot, :subscription_manager)

      capture_log(fn ->
        assert {:error, :subscriptions_not_supported, _message} =
                 WebhookProcessor.process_event(checkout_completed_event())
      end)
    end
  end

  describe "process_event/1 dispatch on the string type" do
    # Production Stripe payloads are string-keyed end to end (see
    # SignatureVerifier and Jason.decode/1 in DevelopmentMode), and the
    # processor hands the event on unchanged, so a handler that matched an
    # atom `:type` key would never match here.
    test "a fully string-keyed event reaches the handler for its type" do
      event = %{
        "id" => "evt_charge_succeeded",
        "type" => "charge.succeeded",
        "created" => 1_700_000_000,
        "livemode" => false,
        "data" => %{
          "object" => %{
            "id" => "ch_123",
            "object" => "charge",
            "amount" => 1000
          }
        }
      }

      assert {:ok, :charge_logged} = WebhookProcessor.process_event(event)
    end
  end
end
