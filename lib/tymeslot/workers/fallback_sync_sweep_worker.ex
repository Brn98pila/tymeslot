defmodule Tymeslot.Workers.FallbackSyncSweepWorker do
  @moduledoc """
  Oban worker that performs a sweep of all active calendar integrations every
  15 minutes as a fallback mechanism for missed or delayed webhook notifications.

  The sweep itself does no provider I/O: it only fans out a sync job per
  integration that `Tymeslot.Integrations.Calendar.SyncSchedule` says is due,
  with the worker its provider syncs with. Google and Outlook are due on
  every sweep, the net for a missed webhook; CalDAV-family integrations by
  their sync tier; subscriptions and Exchange every 30 minutes.

  CalDAV integrations also get a forced full fetch once a day, to recover
  events their tier's delta reads missed.

  Jobs are enqueued in batches of 50, each batch scheduled one second after
  the previous via `scheduled_at`, to avoid thundering-herd load on provider
  APIs and the database without blocking the queue slot.
  """

  use Oban.Worker,
    queue: :calendar_integrations,
    max_attempts: 1,
    # Just under the 15-minute crontab interval: uniqueness counts from the
    # previous job's insertion, so a full 900 would swallow the next slot's
    # job whenever the cron plugin inserts it a moment early.
    unique: [period: 840]

  require Logger

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.ProviderConfig
  alias Tymeslot.Integrations.Calendar.SyncSchedule
  alias Tymeslot.Integrations.HealthCheck.SyncGating
  alias Tymeslot.Workers.SyncCalDavCalendarWorker

  @batch_size 50
  @batch_stagger_seconds 1

  # Forced full fetch: every 24 hours to recover events missed by Tier 1/2
  # delta-based optimisations. Was 12 hours before the reconcile transaction
  # was made atomic (see SyncReconciler.process_full_fetch/6) — with the
  # cache now guaranteed to commit cleanly, the safety-net cadence can be
  # slower without increasing the risk of persistent drift.
  @forced_full_fetch_interval_seconds 24 * 3600

  # Spread forced full-fetch jobs over the next 15 minutes to avoid thundering
  # herd on CalDAV servers.
  @forced_full_fetch_jitter_seconds 900

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    now = DateTime.utc_now()
    paused_ids = SyncGating.paused_integration_ids(:calendar)
    by_provider = drop_paused_integrations(collect_integrations_by_provider(), paused_ids)

    google_count = enqueue_due(Map.get(by_provider, "google", []), now)
    outlook_count = enqueue_due(Map.get(by_provider, "outlook", []), now)

    caldav_providers = Enum.map(ProviderConfig.caldav_based_providers(), &Atom.to_string/1)
    caldav_integrations = Enum.flat_map(caldav_providers, &Map.get(by_provider, &1, []))

    # Enqueue forced full-fetch jobs first so that, for integrations needing
    # both a normal sync and a forced full fetch, Oban's unique constraint on
    # SyncCalDavCalendarWorker (keyed by calendar_integration_id) keeps the
    # forced job rather than deduping it to a plain sync.
    # The subsequent normal enqueue pass will hit Oban's unique conflict for
    # those same integrations and be silently ignored, which is the desired
    # outcome.
    {forced_full_count, forced_full_conflicts} =
      enqueue_caldav_forced_full_fetches(caldav_integrations)

    due_caldav = Enum.filter(caldav_integrations, &SyncSchedule.due?(&1, now))
    caldav_count = enqueue_batched(due_caldav, now)
    caldav_skipped = length(caldav_integrations) - length(due_caldav)

    subscription_count =
      ProviderConfig.subscription_provider_strings()
      |> Enum.flat_map(&Map.get(by_provider, &1, []))
      |> enqueue_due(now)

    exchange_count =
      ProviderConfig.ews_provider_strings()
      |> Enum.flat_map(&Map.get(by_provider, &1, []))
      |> enqueue_due(now)

    Logger.info("FallbackSyncSweep complete",
      google_scheduled: google_count,
      outlook_scheduled: outlook_count,
      caldav_scheduled: caldav_count,
      caldav_skipped: caldav_skipped,
      caldav_forced_full_scheduled: forced_full_count,
      caldav_forced_full_conflicts: forced_full_conflicts,
      subscription_scheduled: subscription_count,
      exchange_scheduled: exchange_count
    )

    :ok
  end

  # ---------------------------------------------------------------------------
  # Integration loading (streamed to avoid unbounded memory)
  # ---------------------------------------------------------------------------

  defp collect_integrations_by_provider do
    CalendarIntegrationQueries.stream_all_active(@batch_size, %{}, fn integration, acc ->
      Map.update(acc, integration.provider, [integration], &[integration | &1])
    end)
  end

  # Drop integrations whose health state indicates sustained hard failures
  # (typically `invalid_grant` after a revoked token). They stay in the DB
  # with `is_active = true` so the dashboard still shows them, but periodic
  # sync stops hammering them until the next successful health check clears
  # the failure counter — which will only happen after the user reauthorises.
  defp drop_paused_integrations(by_provider, paused_ids) do
    if MapSet.size(paused_ids) == 0 do
      by_provider
    else
      Map.new(by_provider, fn {provider, integrations} ->
        kept = Enum.reject(integrations, fn i -> MapSet.member?(paused_ids, i.id) end)

        if length(kept) < length(integrations) do
          Logger.info("Sync gating paused integrations in fallback sweep",
            provider: provider,
            paused_count: length(integrations) - length(kept)
          )
        end

        {provider, kept}
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # Shared batch processing
  # ---------------------------------------------------------------------------

  defp process_in_batches(items, per_item_fun) do
    items
    |> Enum.chunk_every(@batch_size)
    |> Enum.with_index()
    |> Enum.reduce({0, 0}, fn {batch, batch_index}, {total, conflicts} ->
      {batch_count, batch_conflicts} =
        Enum.reduce(batch, {0, 0}, fn item, {count, confl} ->
          case per_item_fun.(item, batch_index) do
            :ok -> {count + 1, confl}
            :conflict -> {count, confl + 1}
            :error -> {count, confl}
          end
        end)

      {total + batch_count, conflicts + batch_conflicts}
    end)
  end

  # The integrations of `integrations` whose sync `SyncSchedule` says is due
  # at `now`, each enqueued with the worker its provider syncs with.
  defp enqueue_due(integrations, now) do
    integrations
    |> Enum.filter(&SyncSchedule.due?(&1, now))
    |> enqueue_batched(now)
  end

  defp enqueue_batched(integrations, now) do
    {scheduled, _conflicts} =
      process_in_batches(integrations, fn integration, batch_index ->
        {:ok, %{worker: worker_module}} = SyncSchedule.schedule(integration)
        args = %{"calendar_integration_id" => integration.id}

        # Stagger each batch by scheduled_at offset instead of sleeping
        # between batches — same thundering-herd pacing without blocking
        # the sweep's queue slot.
        opts =
          if batch_index > 0 do
            [scheduled_at: DateTime.add(now, batch_index * @batch_stagger_seconds, :second)]
          else
            []
          end

        case Oban.insert(worker_module.new(args, opts)) do
          {:ok, %Oban.Job{conflict?: true}} ->
            :conflict

          {:ok, _job} ->
            :ok

          {:error, reason} ->
            Logger.warning("Failed to enqueue worker in fallback sweep",
              worker: worker_module,
              calendar_integration_id: integration.id,
              error: reason
            )

            :error
        end
      end)

    scheduled
  end

  # ---------------------------------------------------------------------------
  # Periodic forced full fetch (recovers events missed by Tier 1/2 optimisations)
  # ---------------------------------------------------------------------------

  defp enqueue_caldav_forced_full_fetches(integrations) do
    now = DateTime.utc_now()
    due = Enum.filter(integrations, &forced_full_fetch_due?(&1, now))

    process_in_batches(due, fn integration, _batch_index ->
      delay_seconds = :rand.uniform(@forced_full_fetch_jitter_seconds)
      scheduled_at = DateTime.add(now, delay_seconds, :second)

      args = %{
        "calendar_integration_id" => integration.id,
        "force_full_fetch" => true
      }

      case Oban.insert(SyncCalDavCalendarWorker.new(args, scheduled_at: scheduled_at)) do
        {:ok, %Oban.Job{conflict?: true}} ->
          :conflict

        {:ok, _job} ->
          :ok

        {:error, reason} ->
          Logger.warning("Failed to enqueue forced full-fetch CalDAV job",
            calendar_integration_id: integration.id,
            error: reason
          )

          :error
      end
    end)
  end

  defp forced_full_fetch_due?(%{last_full_sync_at: nil}, _now), do: true

  defp forced_full_fetch_due?(%{last_full_sync_at: last_full_sync_at}, now) do
    cutoff = DateTime.add(now, -@forced_full_fetch_interval_seconds, :second)
    DateTime.before?(last_full_sync_at, cutoff)
  end
end
