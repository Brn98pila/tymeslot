defmodule Tymeslot.MeetingPayments.Webhooks.CheckoutSessionCompletedLateTest do
  @moduledoc """
  `checkout.session.completed` arriving after its booking expired and its
  payment was failed (the expired webhook, or a disconnect, ran first). The
  money was taken all the same, so the booking is brought back when its slot
  is still free and the payment is refunded when it is not.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :payments
  @moduletag :integration

  @account "acct_TEST_HOST"
  @paid_session %{"payment_status" => "paid", "amount_total" => 5000, "currency" => "eur"}

  import Mox, only: [expect: 3, stub: 3, verify_on_exit!: 1]
  import Tymeslot.Factory

  alias Tymeslot.MeetingPayments.StripeAdapterMock
  alias Tymeslot.MeetingPayments.Webhooks.CheckoutSessionCompleted
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Repo
  alias Tymeslot.Workers.CalendarEventWorker
  alias Tymeslot.Workers.EmailWorker
  alias Tymeslot.Workers.SendBookingPaymentRefunded

  setup :verify_on_exit!

  describe "handle/1 after the booking expired" do
    test "recovers when expired webhook beat the completed webhook (race E3)" do
      # Regression for E3: checkout.session.expired arrived first, transitioning
      # the meeting to expired and booking_payment to failed. The subsequent
      # completed event must recover, its slot being still free: re-confirm the
      # meeting and mark payment paid.
      user = insert(:user)

      meeting =
        insert(:meeting,
          status: "expired",
          organizer_user_id: user.id,
          organizer_email: user.email
        )

      bp =
        insert_payment(
          meeting: meeting,
          status: "failed",
          stripe_checkout_session_id: "cs_RACE_E3"
        )

      event =
        completed_event("evt_RACE_E3", %{
          "id" => "cs_RACE_E3",
          "client_reference_id" => meeting.id,
          "payment_intent" => "pi_RACE_E3"
        })

      assert :ok = CheckoutSessionCompleted.handle(event)

      reloaded_bp = Repo.reload!(bp)
      assert reloaded_bp.status == "paid"
      assert reloaded_bp.paid_at
      assert reloaded_bp.stripe_payment_intent_id == "pi_RACE_E3"
      assert reloaded_bp.last_event_id == "evt_RACE_E3"

      {:ok, reloaded_meeting} = MeetingQueries.get_meeting(meeting.id)
      assert reloaded_meeting.status == "confirmed"
    end

    # The expiry released the slot, and another booking has taken it since:
    # the attendee's money goes back instead of a double booking.
    test "refunds a completion that arrived after expiry once the slot has been taken" do
      user = insert(:user)

      meeting =
        insert(:meeting,
          status: "expired",
          organizer_user_id: user.id,
          organizer_email: user.email
        )

      _taker =
        insert(:meeting,
          status: "confirmed",
          organizer_user_id: user.id,
          start_time: meeting.start_time,
          end_time: meeting.end_time
        )

      bp =
        insert_payment(
          meeting: meeting,
          status: "failed",
          stripe_checkout_session_id: "cs_LATE_TAKEN"
        )

      stub(StripeAdapterMock, :retrieve_payment_intent, fn "pi_LATE_TAKEN", opts ->
        assert opts[:connect_account] == @account
        {:ok, %{"latest_charge" => "ch_LATE_TAKEN"}}
      end)

      expect(StripeAdapterMock, :create_refund, fn params, opts ->
        assert params.charge == "ch_LATE_TAKEN"
        assert params.amount == bp.amount_cents
        assert opts[:connect_account] == @account
        {:ok, %{"id" => "re_LATE_TAKEN"}}
      end)

      event =
        completed_event("evt_LATE_TAKEN", %{
          "id" => "cs_LATE_TAKEN",
          "client_reference_id" => meeting.id,
          "payment_intent" => "pi_LATE_TAKEN"
        })

      assert :ok = CheckoutSessionCompleted.handle(event)

      reloaded_bp = Repo.reload!(bp)
      assert reloaded_bp.status == "refunded"
      assert reloaded_bp.refunded_amount_cents == bp.amount_cents
      assert reloaded_bp.paid_at
      assert reloaded_bp.last_event_id == "evt_LATE_TAKEN"

      {:ok, reloaded_meeting} = MeetingQueries.get_meeting(meeting.id)
      assert reloaded_meeting.status == "expired"

      assert_enqueued(worker: SendBookingPaymentRefunded, args: %{booking_payment_id: bp.id})
      refute_enqueued(worker: CalendarEventWorker)
      refute_enqueued(worker: EmailWorker)
    end

    test "refunds a completion that arrived after expiry for a meeting whose organiser is gone" do
      meeting = insert(:meeting, status: "expired", organizer_user_id: nil)

      bp =
        insert_payment(
          meeting: meeting,
          status: "failed",
          stripe_checkout_session_id: "cs_LATE_ORPHAN"
        )

      stub(StripeAdapterMock, :retrieve_payment_intent, fn _id, _opts ->
        {:ok, %{"latest_charge" => "ch_LATE_ORPHAN"}}
      end)

      expect(StripeAdapterMock, :create_refund, fn %{charge: "ch_LATE_ORPHAN"}, _opts ->
        {:ok, %{"id" => "re_LATE_ORPHAN"}}
      end)

      event =
        completed_event("evt_LATE_ORPHAN", %{
          "id" => "cs_LATE_ORPHAN",
          "client_reference_id" => meeting.id,
          "payment_intent" => "pi_LATE_ORPHAN"
        })

      assert :ok = CheckoutSessionCompleted.handle(event)

      assert Repo.reload!(bp).status == "refunded"
      {:ok, reloaded_meeting} = MeetingQueries.get_meeting(meeting.id)
      assert reloaded_meeting.status == "expired"
    end

    test "leaves a late completion for redelivery when refunding the taken slot fails" do
      user = insert(:user)

      meeting =
        insert(:meeting,
          status: "expired",
          organizer_user_id: user.id,
          organizer_email: user.email
        )

      _taker =
        insert(:meeting,
          status: "confirmed",
          organizer_user_id: user.id,
          start_time: meeting.start_time,
          end_time: meeting.end_time
        )

      bp =
        insert_payment(
          meeting: meeting,
          status: "failed",
          stripe_checkout_session_id: "cs_LATE_FAIL"
        )

      stub(StripeAdapterMock, :retrieve_payment_intent, fn _id, _opts ->
        {:ok, %{"latest_charge" => "ch_LATE_FAIL"}}
      end)

      expect(StripeAdapterMock, :create_refund, fn _params, _opts -> {:error, :stripe_down} end)

      event =
        completed_event("evt_LATE_FAIL", %{
          "id" => "cs_LATE_FAIL",
          "client_reference_id" => meeting.id,
          "payment_intent" => "pi_LATE_FAIL"
        })

      assert {:error, :stripe_down} = CheckoutSessionCompleted.handle(event)

      reloaded_bp = Repo.reload!(bp)
      assert reloaded_bp.status == "failed"
      assert is_nil(reloaded_bp.last_event_id)

      {:ok, reloaded_meeting} = MeetingQueries.get_meeting(meeting.id)
      assert reloaded_meeting.status == "expired"
    end
  end

  defp insert_payment(attrs),
    do: insert(:booking_payment, Keyword.put_new(attrs, :stripe_account_id, @account))

  defp completed_event(event_id, object) do
    %{
      "id" => event_id,
      "account" => @account,
      "type" => "checkout.session.completed",
      "created" => System.os_time(:second),
      "data" => %{"object" => Map.merge(@paid_session, object)}
    }
  end
end
