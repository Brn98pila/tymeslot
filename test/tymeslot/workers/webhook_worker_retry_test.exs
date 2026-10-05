defmodule Tymeslot.Workers.WebhookWorkerRetryTest do
  @moduledoc """
  How long a failed webhook delivery keeps being retried, and that a delivery
  the receiver already accepted is never posted a second time because its
  delivery log could not be written.
  """
  use Tymeslot.DataCase, async: false

  @moduletag :workers
  @moduletag :webhooks

  import Mox
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory
  import Tymeslot.WorkerTestHelpers

  alias Tymeslot.Webhooks.WebhookDeliverySchema
  alias Tymeslot.Webhooks.WebhookSchema
  alias Tymeslot.Workers.WebhookWorker

  setup :verify_on_exit!

  setup do
    setup_config(:tymeslot,
      feature_access_checker: Tymeslot.Features.DefaultAccessChecker,
      environment: :test
    )

    :ok
  end

  describe "perform/1 - delivery log failure after a successful post" do
    # The receiver already has the event: a failed log write must neither fail
    # the job nor release the claim, or the retry would post it again. The
    # trigger fails every delivery-log insert for this test's transaction.
    test "does not post a delivered webhook again" do
      meeting = insert(:meeting)
      webhook = insert(:webhook, failure_count: 2)

      job =
        persisted_job(WebhookWorker, %{
          "webhook_id" => webhook.id,
          "event_type" => "meeting.created",
          "meeting_id" => meeting.id
        })

      fail_delivery_log_inserts()
      expect_http_success()

      try do
        WebhookWorker.perform(job)
      rescue
        Postgrex.Error -> :log_insert_raised
      end

      allow_delivery_log_inserts()

      assert :ok = WebhookWorker.perform(%{job | attempt: 2})
      assert Repo.aggregate(WebhookDeliverySchema, :count) == 0
    end

    test "counts the post as a success when the log insert returns an error" do
      meeting = insert(:meeting)
      webhook = insert(:webhook, failure_count: 2)

      job =
        persisted_job(WebhookWorker, %{
          "webhook_id" => webhook.id,
          "event_type" => "meeting.created",
          "meeting_id" => meeting.id
        })

      fail_delivery_log_inserts(as: :foreign_key)
      expect_http_success()

      assert :ok = WebhookWorker.perform(job)
      assert Repo.get!(WebhookSchema, webhook.id).failure_count == 0

      allow_delivery_log_inserts()
      assert :ok = WebhookWorker.perform(%{job | attempt: 2})
    end
  end

  describe "backoff/1" do
    test "spreads eight attempts over hours, so a receiver outage does not lose the event" do
      assert WebhookWorker.__opts__()[:max_attempts] == 8

      assert Enum.map(1..7, &WebhookWorker.backoff(%Oban.Job{attempt: &1})) ==
               [30, 120, 600, 1_800, 3_600, 10_800, 21_600]
    end

    test "caps the wait at six hours" do
      assert WebhookWorker.backoff(%Oban.Job{attempt: 20}) == 21_600
    end
  end

  # A trigger rejecting every delivery-log insert, rolled back with the test's
  # sandbox transaction. `as: :foreign_key` raises it as the webhook foreign
  # key violation the changeset declares, so the insert returns an error
  # instead of raising.
  defp fail_delivery_log_inserts(opts \\ []) do
    raise_clause =
      case Keyword.get(opts, :as) do
        :foreign_key ->
          "RAISE EXCEPTION 'rejected' USING ERRCODE = 'foreign_key_violation', " <>
            "CONSTRAINT = 'webhook_deliveries_webhook_id_fkey'"

        nil ->
          "RAISE EXCEPTION 'delivery log unavailable'"
      end

    Repo.query!("""
    CREATE FUNCTION test_reject_delivery_log() RETURNS trigger AS $$
    BEGIN #{raise_clause}; END;
    $$ LANGUAGE plpgsql
    """)

    Repo.query!("""
    CREATE TRIGGER test_reject_delivery_log BEFORE INSERT ON webhook_deliveries
    FOR EACH ROW EXECUTE FUNCTION test_reject_delivery_log()
    """)
  end

  defp allow_delivery_log_inserts do
    Repo.query!("DROP TRIGGER test_reject_delivery_log ON webhook_deliveries")
  end
end
