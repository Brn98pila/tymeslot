defmodule Tymeslot.Auth.AccountDeletion.RunnerTest do
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :auth
  @moduletag :integration

  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Auth
  alias Tymeslot.Auth.AccountDeletion
  alias Tymeslot.Auth.AccountDeletion.Runner
  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo
  alias Tymeslot.Workers.{AccountDeletionWorker, EmailWorker, WebhookWorker}

  defmodule RefusingHook do
    @behaviour Tymeslot.Auth.Behaviours.AccountDeletionHook

    @impl Tymeslot.Auth.Behaviours.AccountDeletionHook
    def on_deletion_requested(_user_id, _feedback), do: :ok

    @impl Tymeslot.Auth.Behaviours.AccountDeletionHook
    def on_deletion_restored(_user_id), do: :ok

    @impl Tymeslot.Auth.Behaviours.AccountDeletionHook
    def on_account_deletion(_user_id), do: {:error, :billing_unreachable}
  end

  setup do
    with_config(:tymeslot, :account_deletion_hook, nil)
    :ok
  end

  defp pending_user(scheduled_at) do
    insert(:user,
      deletion_requested_at: DateTime.add(scheduled_at, -14, :day),
      deletion_scheduled_at: DateTime.truncate(scheduled_at, :second)
    )
  end

  defp past, do: DateTime.add(DateTime.utc_now(:second), -60, :second)
  defp future, do: DateTime.add(DateTime.utc_now(:second), 3, :day)

  describe "run/1" do
    test "deletes a due account, its meetings and the jobs queued for them, telling no guest" do
      user = pending_user(past())
      meeting = insert(:meeting, organizer_user: user, organizer_email: user.email)

      %{
        "action" => "send_reminder_emails",
        "meeting_id" => meeting.id,
        "reminder_value" => 1,
        "reminder_unit" => "hours"
      }
      |> EmailWorker.new(scheduled_at: DateTime.add(DateTime.utc_now(), 1, :day))
      |> Oban.insert!()

      assert Runner.run(user.id) == {:ok, :deleted}

      refute Repo.get(UserSchema, user.id)
      refute Repo.get(MeetingSchema, meeting.id)
      assert all_enqueued(worker: EmailWorker) == []
      refute_enqueued(worker: WebhookWorker)
    end

    test "leaves a restored account alone" do
      user = insert(:user)

      assert Runner.run(user.id) == {:ok, :not_pending}
      assert Repo.get(UserSchema, user.id)
    end

    test "snoozes when it runs before the account is due" do
      user = pending_user(future())

      assert {:snooze, seconds} = Runner.run(user.id)
      assert seconds > 2 * 86_400
      assert Repo.get(UserSchema, user.id)
    end

    test "is done when the account is already gone" do
      assert Runner.run(-1) == {:ok, :already_deleted}
    end

    test "returns the hook's refusal so the job retries, and keeps the account" do
      with_config(:tymeslot, :account_deletion_hook, RefusingHook)
      user = pending_user(past())

      assert Runner.run(user.id) == {:error, :billing_unreachable}
      assert Repo.get(UserSchema, user.id)
    end
  end

  describe "AccountDeletion.delete_account/2 with only_if_pending" do
    test "refuses an account that is no longer pending" do
      user = insert(:user)

      assert AccountDeletion.delete_account(user, only_if_pending: true) == {:error, :not_pending}
      assert Repo.get(UserSchema, user.id)
    end
  end

  describe "enqueue_overdue/1" do
    test "queues one job per overdue account, and none twice" do
      overdue = pending_user(past())
      _not_yet = pending_user(future())
      _active = insert(:user)

      assert Auth.enqueue_overdue_account_deletions() == 1
      assert_enqueued(worker: AccountDeletionWorker, args: %{"user_id" => overdue.id})
      assert Auth.enqueue_overdue_account_deletions() == 0
    end
  end
end
