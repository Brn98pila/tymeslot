defmodule Tymeslot.Workers.RefreshOutlookCalendarWorker do
  @moduledoc """
  Oban worker that refreshes a single Outlook Calendar integration.

  Outlook syncs are normally event-driven via Microsoft Graph webhooks; this
  worker covers the cases where that is not enough: a user-initiated
  "Refresh now" click, and the periodic `FallbackSyncSweepWorker`, which
  enqueues one of these jobs per Outlook integration to catch missed,
  delayed, or never-delivered notifications (e.g. WEBHOOK_BASE_URL not
  configured).

  If the integration has a `graph_delta_link`, delta-syncs via
  `OutlookDeltaSync.fetch_and_apply/1`; otherwise bootstraps a fresh delta
  baseline via `OutlookCalendarAPI.bootstrap_sync/1` and opportunistically
  registers a webhook subscription.

  A link old enough to be replaced (`OutlookDeltaSync.rebootstrap_due?/2`) is
  still followed first, then replaced by a bootstrap. The bootstrap only
  upserts what it reads, so the removals pending on the old link would
  otherwise never reach the cache; and a bootstrap that keeps failing (a
  calendar past its page cap, say) would otherwise freeze the cache, since
  every later refresh would try the bootstrap again and nothing else.

  Broadcasts `SyncBroadcast.broadcast_sync_complete/2` on success so the
  dashboard's progress counter clears.

  A failure that is the remote's and has used up every attempt is discarded
  rather than failed, so a passing Graph outage does not raise a permanent
  failure admin alert; see `give_up_or_retry/3`.
  """

  use Oban.Worker,
    queue: :calendar_integrations,
    max_attempts: 5,
    unique: [
      period: 60,
      keys: [:calendar_integration_id],
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

  use Gettext, backend: TymeslotWeb.Gettext

  require Logger

  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Infrastructure.ExpectedJobOutcome
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.Outlook.DeltaSync, as: OutlookDeltaSync
  alias Tymeslot.Integrations.Calendar.SyncBroadcast
  alias Tymeslot.Integrations.CalendarManagement
  alias Tymeslot.Integrations.HealthCheck.ErrorAnalysis
  alias Tymeslot.Integrations.Shared.ReauthHandling
  alias Tymeslot.Workers.CalendarSyncJob
  alias Tymeslot.Workers.SyncRequest

  @behaviour ExpectedJobOutcome

  # The integration is gone, or only its owner can fix it by reconnecting.
  # A transient failure is retried by the next sweep. A job for an integration
  # that is not Outlook is a bug, and is recorded.
  @integration_gone "Integration not found"
  @transient "Outlook sync failed transiently; the next scheduled sweep will retry"
  @credentials_rejected "Microsoft Graph rejected credentials — reauthentication required"

  @impl ExpectedJobOutcome
  def expected_outcome?(reason),
    do:
      reason in [@integration_gone, @transient, @credentials_rejected] or
        reason == ReauthHandling.discard_reason()

  @doc """
  Enqueues a refresh of the Outlook integration `integration_id`, the one
  the dashboard's Refresh asks for. A refresh already waiting for the
  integration runs in its place; one already running runs again once it
  finishes, since it may have read Outlook before the request (see
  `Tymeslot.Workers.SyncRequest`).
  """
  @spec enqueue(pos_integer()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(integration_id),
    do: SyncRequest.insert(__MODULE__, %{"calendar_integration_id" => integration_id})

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}) do
    # Progressive backoff: 30s, 90s, 240s, 480s. Graph returns transient 500s
    # and connection timeouts that outlast the default schedule, which retries
    # a job to exhaustion inside ~70 seconds and then alerts an operator about
    # what was a one-minute upstream blip. The four gaps total 14 minutes, so
    # the retries resolve before `FallbackSyncSweepWorker` (every 15 minutes)
    # enqueues the next refresh for the same integration.
    case attempt do
      1 -> 30
      2 -> 90
      3 -> 240
      _later -> 480
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{} = job),
    do: CalendarSyncJob.run(job, &refresh(&1, job), provider: "outlook")

  defp refresh(%{graph_delta_link: nil} = integration, job), do: bootstrap(integration, job)

  defp refresh(integration, job) do
    if OutlookDeltaSync.rebootstrap_due?(integration),
      do: delta_then_bootstrap(integration, job),
      else: delta_refresh(integration, job)
  end

  # See the moduledoc. A bootstrap that fails after the old link was followed
  # keeps that result: the cache is as current as the old link can make it,
  # and the next refresh tries the bootstrap again. A refused credential is
  # the one bootstrap failure that still decides the outcome.
  defp delta_then_bootstrap(integration, job) do
    case OutlookDeltaSync.fetch_and_apply(integration) do
      {:error, :unauthorized} ->
        handle_credentials_rejected(integration)

      delta_result ->
        case run_bootstrap(reload(integration)) do
          {:error, :unauthorized, _message} = refused ->
            bootstrap_outcome(refused, integration, job)

          failure when delta_result == :ok and failure != :ok ->
            log_bootstrap_failure(integration, failure)
            broadcast_complete(integration)
            :ok

          bootstrap_result ->
            bootstrap_outcome(bootstrap_result, integration, job)
        end
    end
  end

  # The delta pass may have stored a new link and refreshed the token.
  defp reload(integration) do
    case CalendarIntegrationQueries.get(integration.id) do
      {:ok, reloaded} -> reloaded
      _gone_or_unreadable -> integration
    end
  end

  defp delta_refresh(integration, job) do
    case OutlookDeltaSync.fetch_and_apply(integration) do
      :ok ->
        broadcast_complete(integration)
        :ok

      {:error, :unauthorized} ->
        handle_credentials_rejected(integration)

      {:error, class} ->
        # DeltaSync clears the stored link on obsolete-endpoint detection (old
        # `events/delta`) or 410 expiry. Reload to see whether that happened —
        # if so, finish the job by bootstrapping rather than relying on an
        # Oban retry to converge on the second pass.
        case CalendarIntegrationQueries.get(integration.id) do
          {:ok, %{graph_delta_link: nil} = reloaded} -> bootstrap(reloaded, job)
          _other -> give_up_or_retry(class, job, :delta_sync_failed)
        end
    end
  end

  defp bootstrap(integration, job),
    do: integration |> run_bootstrap() |> bootstrap_outcome(integration, job)

  defp run_bootstrap(integration) do
    case Config.outlook_calendar_api_module().bootstrap_sync(integration) do
      {:ok, updated} ->
        # Opportunistic webhook (re-)registration. Non-fatal: a seeded delta
        # link is enough on its own, the next click/sweep can keep things current.
        Config.outlook_calendar_api_module().register_graph_subscription(updated)
        broadcast_complete(updated)
        :ok

      error ->
        error
    end
  end

  defp bootstrap_outcome(:ok, _integration, _job), do: :ok

  defp bootstrap_outcome({:error, :unauthorized, _message}, integration, _job),
    do: handle_credentials_rejected(integration)

  defp bootstrap_outcome(error, integration, job) do
    log_bootstrap_failure(integration, error)
    give_up_or_retry(error_class(error), job, :bootstrap_failed)
  end

  defp log_bootstrap_failure(integration, error) do
    Logger.warning("Outlook bootstrap failed during manual refresh",
      calendar_integration_id: integration.id,
      error: LogFormat.reason(error)
    )
  end

  # A transient Graph failure that has spent the whole retry ladder is not an
  # operator's problem: `FallbackSyncSweepWorker` re-enqueues this integration
  # within 15 minutes, and a remote that never comes back is surfaced by the
  # health check rather than by one discarded job. Discarding keeps a passing
  # upstream blip out of the admin alerts; the underlying status and reason are
  # already logged by whichever call failed. Anything `:hard` — bad credentials,
  # a failed local write — keeps failing loudly.
  defp give_up_or_retry(:transient, %Oban.Job{attempt: attempt, max_attempts: max_attempts}, _rsn)
       when attempt >= max_attempts do
    {:discard, @transient}
  end

  defp give_up_or_retry(_class, _job, reason), do: {:error, reason}

  defp error_class({:error, type, _message}) when is_atom(type),
    do: ErrorAnalysis.classify_error(type)

  defp error_class({:error, reason}), do: ErrorAnalysis.classify_error(reason)
  defp error_class(_other), do: :hard

  # Retrying a refused credential cannot help; only the owner reconnecting can.
  defp handle_credentials_rejected(integration) do
    CalendarManagement.flag_for_reconnection(
      integration,
      dgettext(
        "dashboard_calendar_providers",
        "Microsoft rejected the stored credentials. Please reconnect the integration."
      ),
      @credentials_rejected
    )
  end

  defp broadcast_complete(integration) do
    SyncBroadcast.broadcast_sync_complete(integration.user_id, integration.id)
  end
end
