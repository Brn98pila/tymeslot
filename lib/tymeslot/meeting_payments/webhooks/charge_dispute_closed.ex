defmodule Tymeslot.MeetingPayments.Webhooks.ChargeDisputeClosed do
  @moduledoc """
  Handler for the Stripe `charge.dispute.closed` Connect event.

  Reconciles status after a dispute is decided:

    * `won` → revert to `paid` (or `partially_refunded` if any prior
      refund was on the row before the dispute opened)
    * `lost` → set `refunded_amount_cents` to the disputed amount and
      derive `refunded` / `partially_refunded` accordingly. Stripe debits
      the host's balance for the disputed amount when a dispute is lost,
      so the row should reflect the funds being gone from the host's
      perspective.
    * other statuses (`warning_closed`, `warning_under_review`, …) are
      not decisive — leave the booking in `disputed` and ignore.

  Idempotent on `last_event_id`.
  """

  require Logger

  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.MeetingPayments.Telemetry
  alias Tymeslot.MeetingPayments.Webhooks.LockedPayment
  alias Tymeslot.MeetingPayments.Webhooks.PaymentLookup

  @event_type "charge.dispute.closed"

  @spec handle(map()) :: :ok | {:error, term()}
  def handle(event) do
    Telemetry.span_webhook(@event_type, fn -> do_handle(event) end)
  end

  defp do_handle(%{"id" => event_id, "data" => %{"object" => object}} = event) do
    case PaymentLookup.find_for_charge(event, object["charge"]) do
      nil ->
        Logger.info("charge.dispute.closed: no booking_payment matched",
          charge_id: object["charge"]
        )

        {:ok, :ok}

      %BookingPaymentSchema{last_event_id: ^event_id} ->
        {:ok, :idempotent_replay}

      payment ->
        classify(apply_outcome(payment, event_id, object["status"], object["amount"] || 0))
    end
  end

  defp do_handle(_other), do: {{:error, :invalid_event}, :error}

  defp classify(:ok), do: {:ok, :ok}
  defp classify({:error, _reason} = err), do: {err, :error}

  # Decided from the locked row (`LockedPayment`): a `charge.refunded`
  # committed since the row was resolved must be counted, not written over.
  defp apply_outcome(payment, event_id, status, disputed_amount)
       when status in ["won", "lost"] do
    result =
      LockedPayment.run(payment, event_id, fn locked ->
        case BookingPaymentQueries.update(
               locked,
               Map.put(outcome_attrs(locked, status, disputed_amount), :last_event_id, event_id)
             ) do
          {:ok, updated} -> {:ok, {locked.status, updated.status}}
          {:error, _changeset} = error -> error
        end
      end)

    case result do
      {:ok, :idempotent_replay} ->
        :ok

      {:ok, {old_status, new_status}} ->
        Telemetry.emit_status_changed(old_status, new_status, :webhook_dispute_closed)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp apply_outcome(_payment, _event_id, _status, _amount), do: :ok

  defp outcome_attrs(payment, "won", _disputed_amount),
    do: %{status: derive_status_from_refund(payment, payment.refunded_amount_cents)}

  defp outcome_attrs(payment, "lost", disputed_amount) do
    new_total = max(payment.refunded_amount_cents, disputed_amount)
    %{status: derive_status_from_refund(payment, new_total), refunded_amount_cents: new_total}
  end

  defp derive_status_from_refund(%{amount_cents: amount_cents}, refunded) do
    cond do
      refunded >= amount_cents -> "refunded"
      refunded > 0 -> "partially_refunded"
      true -> "paid"
    end
  end
end
