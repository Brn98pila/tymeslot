defmodule Tymeslot.Workers.ChatWorkerAccessTest do
  @moduledoc """
  What the Slack and Telegram delivery workers do with each answer to the
  organiser's automations access check, which they share through
  `Tymeslot.Workers.MeetingNotificationJob.feature_gate/1`.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :workers
  @moduletag :notifications

  use Oban.Testing, repo: Tymeslot.Repo
  import Mox
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Slack.SlackIntegrationSchema
  alias Tymeslot.Telegram.TelegramIntegrationSchema
  alias Tymeslot.Test.ProcessAccessChecker
  alias Tymeslot.Workers.{SlackWorker, TelegramWorker}

  setup :verify_on_exit!

  setup do
    setup_config(:tymeslot,
      feature_access_checker: ProcessAccessChecker,
      slack_notifications_allowed: true,
      telegram_notifications_allowed: true,
      telegram_shared_bot: false,
      http_client_module: Tymeslot.HTTPClientMock
    )

    # No answer reaches the provider.
    expect(Tymeslot.HTTPClientMock, :post, 0, fn _url, _body, _headers, _opts -> :unused end)

    user = insert(:user)
    %{user: user, meeting: insert(:meeting, organizer_user_id: user.id)}
  end

  for {factory, worker, schema} <- [
        {:slack_integration, SlackWorker, SlackIntegrationSchema},
        {:telegram_integration, TelegramWorker, TelegramIntegrationSchema}
      ] do
    describe "#{inspect(worker)} and the automations access check" do
      setup %{user: user} do
        %{integration: insert(unquote(factory), user: user)}
      end

      for reason <- [:insufficient_plan, :pro_required, :stripe_required] do
        test "switches the integration off when the plan answers #{reason}", %{
          integration: integration,
          meeting: meeting
        } do
          ProcessAccessChecker.answer({:error, unquote(reason)})

          assert {:discard, "Insufficient plan"} =
                   perform_job(unquote(worker), args(integration, meeting))

          updated = Repo.get!(unquote(schema), integration.id)
          refute updated.is_active
          assert updated.disabled_reason == "Plan no longer permits automations"
        end
      end

      test "discards without switching the integration off when automations are off", %{
        integration: integration,
        meeting: meeting
      } do
        ProcessAccessChecker.answer({:error, :feature_disabled})

        assert {:discard, "Automations are switched off"} =
                 perform_job(unquote(worker), args(integration, meeting))

        updated = Repo.get!(unquote(schema), integration.id)
        assert updated.is_active
        assert is_nil(updated.disabled_at)
      end

      test "retries, leaving the integration alone, when the access check fails", %{
        integration: integration,
        meeting: meeting
      } do
        ProcessAccessChecker.answer({:error, :checker_unavailable})

        assert {:error, :feature_access_checker_failed} =
                 perform_job(unquote(worker), args(integration, meeting))

        updated = Repo.get!(unquote(schema), integration.id)
        assert updated.is_active
        assert updated.failure_count == 0
      end
    end
  end

  defp args(integration, meeting) do
    %{
      "integration_id" => integration.id,
      "event_type" => "meeting.created",
      "meeting_id" => meeting.id
    }
  end
end
