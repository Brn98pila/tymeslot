defmodule Tymeslot.MeetingPayments.Webhooks.PaymentTransitionsConcurrencyTest do
  @moduledoc """
  Races between the Connect webhook handlers that move one booking payment,
  on real connections, staged by `Tymeslot.Test.RaceConductor` (see its
  moduledoc for why the module is synchronous and why `on_exit` deletes what
  it committed).

  Each handler resolves its row before opening a transaction, so without a
  row lock taken inside the transaction a contender decides from a copy that
  another handler has since moved on.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :payments
  @moduletag :webhooks
  @moduletag :integration

  import Ecto.Query, only: [from: 2]
  import Tymeslot.Factory
  import Tymeslot.Test.RaceConductor, only: [race: 1, unboxed: 1]

  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.MeetingPayments.Webhooks.ChargeDisputeClosed
  alias Tymeslot.MeetingPayments.Webhooks.ChargeRefunded
  alias Tymeslot.MeetingPayments.Webhooks.CheckoutSessionCompleted
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo
  alias Tymeslot.Test.RaceConductor

  @account "acct_RACE_HOST"
  @succeeded [:tymeslot, :meeting_payments, :booking_payment, :succeeded]

  setup do
    user = unboxed(fn -> insert(:user) end)

    on_exit(fn ->
      unboxed(fn ->
        meeting_ids =
          Repo.all(from(m in MeetingSchema, where: m.organizer_user_id == ^user.id, select: m.id))

        Repo.delete_all(from(b in BookingPaymentSchema, where: b.host_user_id == ^user.id))

        Repo.delete_all(
          from(j in Oban.Job, where: fragment("?->>'meeting_id'", j.args) in ^meeting_ids)
        )

        Repo.delete_all(from(m in MeetingSchema, where: m.organizer_user_id == ^user.id))
        Repo.delete_all(from(u in UserSchema, where: u.id == ^user.id))
      end)
    end)

    RaceConductor.attach_parking()

    %{user: user}
  end

  # The cron reconciler replays `checkout.session.completed` under its own
  # synthetic event id, so the replay guard on `last_event_id` cannot tell it
  # apart from Stripe's own retry of the same completion.
  test "a webhook and the reconciler completing one payment activate the booking once", ctx do
    test_pid = self()
    handler_id = "count-activations-#{inspect(make_ref())}"

    :ok =
      :telemetry.attach(
        handler_id,
        @succeeded,
        fn _event, _measurements, _metadata, _config -> send(test_pid, :activated) end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {meeting, _payment} = awaiting_payment_booking(ctx.user, "cs_RACE_DOUBLE")

    results =
      race([
        fn hold -> complete(hold, "evt_RACE_DOUBLE", meeting) end,
        fn hold -> complete(hold, "reconcile:cs_RACE_DOUBLE", meeting) end
      ])

    assert results == [:ok, :ok]
    assert_received :activated
    refute_received :activated
    assert unboxed(fn -> Repo.get!(MeetingSchema, meeting.id).status end) == "confirmed"
  end

  test "a lost dispute racing a larger refund keeps the larger refunded amount", ctx do
    payment =
      unboxed(fn ->
        insert(:paid_booking_payment,
          host_user_id: ctx.user.id,
          stripe_account_id: @account,
          stripe_charge_id: "ch_RACE_REFUND"
        )
      end)

    results =
      race([
        fn hold ->
          # Parks holding the row it has just written, before committing.
          RaceConductor.arm(hold, update_of("booking_payments"))

          ChargeRefunded.handle(
            charge_event("evt_REFUNDED", payment, %{"amount_refunded" => 3000})
          )
        end,
        fn hold ->
          # Parks right after resolving the row, before the refund commits.
          RaceConductor.arm(hold, read_of("booking_payments"))

          ChargeDisputeClosed.handle(
            charge_event("evt_DISPUTE_LOST", payment, %{
              "charge" => payment.stripe_charge_id,
              "status" => "lost",
              "amount" => 2000
            })
          )
        end
      ])

    assert results == [:ok, :ok]

    reloaded = unboxed(fn -> Repo.get!(BookingPaymentSchema, payment.id) end)
    assert reloaded.refunded_amount_cents == 3000
    assert reloaded.status == "partially_refunded"
  end

  defp complete(hold, event_id, meeting) do
    # Parks holding the payment row it has just written, before committing.
    RaceConductor.arm(hold, update_of("booking_payments"))

    CheckoutSessionCompleted.handle(%{
      "id" => event_id,
      "account" => @account,
      "type" => "checkout.session.completed",
      "data" => %{
        "object" => %{
          "id" => "cs_RACE_DOUBLE",
          "client_reference_id" => meeting.id,
          "payment_intent" => "pi_RACE_DOUBLE",
          "payment_status" => "paid",
          "amount_total" => 5000,
          "currency" => "eur"
        }
      }
    })
  end

  defp awaiting_payment_booking(user, session_id) do
    unboxed(fn ->
      meeting =
        insert(:meeting,
          status: "awaiting_payment",
          organizer_user_id: user.id,
          organizer_email: user.email
        )

      payment =
        insert(:booking_payment,
          meeting_id: meeting.id,
          host_user_id: user.id,
          stripe_account_id: @account,
          stripe_checkout_session_id: session_id
        )

      {meeting, payment}
    end)
  end

  defp charge_event(event_id, payment, object) do
    %{
      "id" => event_id,
      "account" => @account,
      "data" => %{"object" => Map.put_new(object, "id", payment.stripe_charge_id)}
    }
  end

  defp update_of(table),
    do: &(&1[:source] == table and String.starts_with?(&1[:query], "UPDATE"))

  defp read_of(table),
    do: &(&1[:source] == table and String.starts_with?(&1[:query], "SELECT"))
end
