defmodule Tymeslot.Notifications.OrchestratorLifecycleTest do
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :notifications

  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.Notifications.Orchestrator
  alias Tymeslot.Repo
  alias Tymeslot.Workers.EmailWorker

  defmodule SuccessWorker do
    @spec schedule_cancellation_emails(term()) :: :ok
    def schedule_cancellation_emails(meeting_id) do
      send(self(), {:scheduled_cancellation, meeting_id})
      :ok
    end
  end

  defmodule FailingWorker do
    @spec schedule_cancellation_emails(term()) :: {:error, String.t()}
    def schedule_cancellation_emails(_meeting_id) do
      {:error, "queue down"}
    end
  end

  # Confirmation enqueue fails, reminders schedule normally.
  defmodule ConfirmationFailingWorker do
    @spec schedule_confirmation_emails(term()) :: {:error, String.t()}
    def schedule_confirmation_emails(_meeting_id), do: {:error, "queue down"}

    @spec schedule_reminder_emails(term(), term(), term(), term()) :: :ok
    def schedule_reminder_emails(meeting_id, value, unit, _scheduled_at) do
      send(self(), {:scheduled_reminder, meeting_id, value, unit})
      :ok
    end
  end

  defmodule SuccessEmailService do
    @spec send_reschedule_emails(map()) :: {{:ok, term()}, {:ok, term()}}
    def send_reschedule_emails(content) do
      # The email job sends from a task; tell the test process that started it.
      send(List.last(Process.get(:"$callers", [self()])), {:reschedule_emails_sent, content})
      {{:ok, :organizer_email}, {:ok, :attendee_email}}
    end
  end

  defmodule CircuitOpenEmailService do
    @spec send_reschedule_emails(map()) :: {{:error, :circuit_open}, {:error, :circuit_open}}
    def send_reschedule_emails(_content), do: {{:error, :circuit_open}, {:error, :circuit_open}}
  end

  defmodule PartialFailureEmailService do
    @spec send_reschedule_emails(map()) :: {{:ok, term()}, {:error, term()}}
    def send_reschedule_emails(content) do
      send(List.last(Process.get(:"$callers", [self()])), {:reschedule_emails_partial, content})
      {{:ok, :organizer_email}, {:error, :smtp_down}}
    end
  end

  setup do
    original_worker = Application.get_env(:tymeslot, :email_worker_module)
    original_service = Application.get_env(:tymeslot, :email_service_module)

    on_exit(fn ->
      restore_env(:email_worker_module, original_worker)
      restore_env(:email_service_module, original_service)
    end)

    :ok
  end

  defp restore_env(key, nil), do: Application.delete_env(:tymeslot, key)
  defp restore_env(key, value), do: Application.put_env(:tymeslot, key, value)

  defp meeting_for_lifecycle(attrs \\ %{}, builder \\ &insert/2) do
    user = insert(:user)
    insert(:profile, user: user, timezone: "Europe/London")

    builder.(
      :meeting,
      Map.merge(
        %{
          organizer_user_id: user.id,
          organizer_name: "Alice",
          organizer_email: "alice@example.com",
          attendee_name: "Bob",
          attendee_email: "bob@example.com",
          attendee_timezone: "America/New_York"
        },
        attrs
      )
    )
  end

  describe "schedule_meeting_notifications/1" do
    # The announcement is claimed before this runs and nothing retries it, so
    # a failed confirmation enqueue must not cost the booking its reminders.
    test "still schedules the reminders when the confirmation fails to enqueue" do
      Application.put_env(:tymeslot, :email_worker_module, ConfirmationFailingWorker)

      meeting =
        meeting_for_lifecycle(%{
          start_time: DateTime.add(DateTime.utc_now(), 2, :day),
          end_time: DateTime.add(DateTime.utc_now(), 2 * 86_400 + 1_800, :second),
          reminders: [%{"value" => 1, "unit" => "hours"}]
        })

      assert {:error, [confirmation: "queue down"]} =
               Orchestrator.schedule_meeting_notifications(meeting)

      assert_received {:scheduled_reminder, meeting_id, 1, "hours"}
      assert meeting_id == meeting.id
    end
  end

  describe "send_cancellation_notifications/1" do
    test "schedules the cancellation job for the meeting" do
      Application.put_env(:tymeslot, :email_worker_module, SuccessWorker)
      meeting = meeting_for_lifecycle()

      assert {:ok, :cancellation_scheduled} =
               Orchestrator.send_cancellation_notifications(meeting)

      assert_received {:scheduled_cancellation, meeting_id}
      assert meeting_id == meeting.id
    end

    test "returns an error when recipients are incomplete" do
      Application.put_env(:tymeslot, :email_worker_module, SuccessWorker)
      meeting = meeting_for_lifecycle(%{organizer_email: nil}, &build/2)

      assert {:error, message} = Orchestrator.send_cancellation_notifications(meeting)
      assert message =~ "organizer"
      refute_received {:scheduled_cancellation, _}
    end

    test "propagates worker failure" do
      Application.put_env(:tymeslot, :email_worker_module, FailingWorker)
      meeting = meeting_for_lifecycle()

      assert {:error, "queue down"} =
               Orchestrator.send_cancellation_notifications(meeting)
    end
  end

  describe "send_reschedule_notifications/2" do
    # The notices go out from a retrying email job carrying the time the
    # booking moved from, which the meeting row no longer holds.
    test "schedules the notices, which deliver to both parties with the previous time" do
      Application.put_env(:tymeslot, :email_service_module, SuccessEmailService)

      original =
        meeting_for_lifecycle(%{
          start_time: ~U[2026-06-01 10:00:00Z],
          end_time: ~U[2026-06-01 11:00:00Z]
        })

      updated =
        original
        |> Changeset.change(
          start_time: ~U[2026-06-02 14:00:00Z],
          end_time: ~U[2026-06-02 15:00:00Z]
        )
        |> Repo.update!()

      assert {:ok, :reschedules_scheduled} =
               Orchestrator.send_reschedule_notifications(updated, original)

      refute_received {:reschedule_emails_sent, _content}

      assert [job] =
               all_enqueued(worker: EmailWorker, args: %{"action" => "send_reschedule_emails"})

      assert job.args["original"]["start_time"] == "2026-06-01T10:00:00Z"
      assert :ok = perform_job(EmailWorker, job.args)

      assert_received {:reschedule_emails_sent, content}
      assert content.organizer_email == "alice@example.com"
      assert content.attendee_email == "bob@example.com"
      assert content.is_rescheduled == true
      assert content.original_start_time == ~U[2026-06-01 10:00:00Z]
      assert content.start_time == ~U[2026-06-02 14:00:00Z]
    end

    # With the mail provider unavailable nobody may be left untold that the
    # booking moved: the job waits the outage out instead.
    test "a mail outage delays the notices rather than losing them" do
      Application.put_env(:tymeslot, :email_service_module, CircuitOpenEmailService)
      meeting = meeting_for_lifecycle()

      assert {:ok, :reschedules_scheduled} =
               Orchestrator.send_reschedule_notifications(meeting, meeting)

      assert [job] =
               all_enqueued(worker: EmailWorker, args: %{"action" => "send_reschedule_emails"})

      assert {:snooze, _seconds} = perform_job(EmailWorker, job.args)
    end

    test "a partial delivery is not repeated" do
      Application.put_env(:tymeslot, :email_service_module, PartialFailureEmailService)
      meeting = meeting_for_lifecycle()

      assert {:ok, :reschedules_scheduled} =
               Orchestrator.send_reschedule_notifications(meeting, meeting)

      assert [job] =
               all_enqueued(worker: EmailWorker, args: %{"action" => "send_reschedule_emails"})

      assert {:discard, _reason} = perform_job(EmailWorker, job.args)
      assert_received {:reschedule_emails_partial, _content}
    end

    test "schedules nothing when recipients are incomplete" do
      Application.put_env(:tymeslot, :email_service_module, SuccessEmailService)
      meeting = meeting_for_lifecycle(%{attendee_email: nil}, &build/2)

      assert {:error, _reason} = Orchestrator.send_reschedule_notifications(meeting, meeting)
      assert all_enqueued(worker: EmailWorker) == []
    end
  end
end
