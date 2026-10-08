defmodule Tymeslot.CalendarGrid.Freshness do
  @moduledoc """
  How fresh the calendar grid's cached events are, and the refresh that
  brings them up to date: which integrations are stale, the oldest sync
  among them, and enqueueing a sync of every active integration.
  """

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.ProviderConfig
  alias Tymeslot.Integrations.CalendarManagement
  alias Tymeslot.Workers.RefreshOutlookCalendarWorker
  alias Tymeslot.Workers.SyncCalDavCalendarWorker
  alias Tymeslot.Workers.SyncDebugCalendarWorker
  alias Tymeslot.Workers.SyncExchangeCalendarWorker
  alias Tymeslot.Workers.SyncGoogleCalendarWorker
  alias Tymeslot.Workers.SyncIcsCalendarWorker

  @caldav_providers ProviderConfig.caldav_based_provider_strings()

  # Staleness thresholds (minutes). Each threshold is the sync interval
  # plus a buffer for queue wait, network latency, and retries.
  @webhook_stale_minutes 30
  @caldav_tier_stale_minutes %{
    1 => 25,
    2 => 45,
    3 => 90
  }
  @caldav_default_stale_minutes 25
  @debug_stale_minutes 15
  # Subscriptions are swept every 30 minutes; the buffer is wider than the
  # CalDAV ones because the publisher's own regeneration schedule sits on top
  # of ours, so a feed being an hour old is normal rather than a symptom.
  @subscription_stale_minutes 75
  # Exchange is swept on the same 30-minute cadence as a subscription, and for
  # the same reason: no delta mechanism, so every run re-reads the whole
  # window twice over. The buffer is the sweep interval plus queue wait.
  @exchange_stale_minutes 45

  @doc """
  Enqueues sync workers for all active integrations belonging to the user.

  Each integration is dispatched to the appropriate worker based on its provider:
  - `"google"` → `SyncGoogleCalendarWorker`
  - `"outlook"` → `RefreshOutlookCalendarWorker` (delta sync or bootstrap; the
    standard webhook-driven `SyncOutlookCalendarWorker` is per-event and can't
    service a manual refresh on its own)
  - `"debug"` → `SyncDebugCalendarWorker`
  - `"ics_url"` → `SyncIcsCalendarWorker`
  - `"exchange"` → `SyncExchangeCalendarWorker`
  - any provider returned by `ProviderConfig.caldav_based_providers/0` →
    `SyncCalDavCalendarWorker`

  Returns `{:ok, %{enqueued: count, errors: [{integration_id, reason}]}}`.
  """
  @spec refresh_events(integer()) ::
          {:ok,
           %{
             enqueued: non_neg_integer(),
             skipped: non_neg_integer(),
             errors: [{integer(), term()}]
           }}
  def refresh_events(user_id) do
    # The context call decrypts credentials; acceptable overhead for a
    # user-initiated refresh since we need id + provider for each integration.
    integrations = CalendarManagement.list_active_calendar_integrations(user_id)

    {enqueued, skipped, errors} =
      Enum.reduce(integrations, {0, 0, []}, fn integration, {count, skip, errs} ->
        case request_sync(integration) do
          {:ok, _job} -> {count + 1, skip, errs}
          {:error, reason} -> {count, skip, [{integration.id, reason} | errs]}
        end
      end)

    {:ok, %{enqueued: enqueued, skipped: skipped, errors: errors}}
  end

  @doc """
  Returns integrations whose cached data is stale.

  An integration is stale when `last_external_sync_at` is nil or older than the
  provider-appropriate threshold:
  - Webhook providers (Google, Outlook): #{@webhook_stale_minutes} min
  - CalDAV Tier 1 (sync-token, syncs every 15 min): #{@caldav_tier_stale_minutes[1]} min
  - CalDAV Tier 2 (CTag, syncs every 30 min): #{@caldav_tier_stale_minutes[2]} min
  - CalDAV Tier 3 (full fetch, syncs every 60 min): #{@caldav_tier_stale_minutes[3]} min
  - Calendar subscriptions (full fetch, syncs every 30 min): #{@subscription_stale_minutes} min
  """
  @spec stale_integrations([CalendarIntegrationSchema.t()]) :: [CalendarIntegrationSchema.t()]
  def stale_integrations(integrations) do
    now = DateTime.utc_now()
    Enum.filter(integrations, &stale?(&1, now))
  end

  @doc """
  Returns the oldest `last_external_sync_at` across the given integrations,
  or nil when none have synced.
  """
  @spec oldest_sync_at([CalendarIntegrationSchema.t()]) :: DateTime.t() | nil
  def oldest_sync_at([]), do: nil

  def oldest_sync_at(integrations) do
    timestamps =
      integrations
      |> Enum.map(& &1.last_external_sync_at)
      |> Enum.reject(&is_nil/1)

    if timestamps == [], do: nil, else: Enum.min(timestamps, DateTime)
  end

  # Private

  # Outlook pending initial setup: subscription registration hasn't succeeded yet
  # (e.g. WEBHOOK_BASE_URL not configured). This is "pending", not "stale" —
  # showing a stale banner the user can't resolve is just noise.
  defp stale?(%{provider: "outlook", graph_delta_link: nil, last_external_sync_at: nil}, _now),
    do: false

  defp stale?(%{last_external_sync_at: nil}, _now), do: true

  defp stale?(integration, now) do
    threshold = stale_threshold_minutes(integration)
    cutoff = DateTime.add(now, -threshold, :minute)
    DateTime.before?(integration.last_external_sync_at, cutoff)
  end

  defp stale_threshold_minutes(%{provider: "debug"}), do: @debug_stale_minutes

  defp stale_threshold_minutes(%{provider: "ics_url"}), do: @subscription_stale_minutes

  defp stale_threshold_minutes(%{provider: "exchange"}), do: @exchange_stale_minutes

  defp stale_threshold_minutes(%{provider: provider, caldav_sync_tier: tier})
       when provider in @caldav_providers do
    Map.get(@caldav_tier_stale_minutes, tier, @caldav_default_stale_minutes)
  end

  defp stale_threshold_minutes(_integration), do: @webhook_stale_minutes

  @doc """
  Enqueues a sync of `integration` with the worker its provider uses.
  """
  @spec request_sync(CalendarIntegrationSchema.t()) :: {:ok, term()} | {:error, term()}
  def request_sync(%{provider: "google"} = integration),
    do: SyncGoogleCalendarWorker.enqueue(integration.id)

  def request_sync(%{provider: "outlook"} = integration),
    do: RefreshOutlookCalendarWorker.enqueue(integration.id)

  def request_sync(%{provider: "debug"} = integration) do
    %{"calendar_integration_id" => integration.id}
    |> SyncDebugCalendarWorker.new()
    |> Oban.insert()
  end

  # A subscription refresh is always a full re-fetch of the feed; there is no
  # delta mode to force past.
  def request_sync(%{provider: "ics_url"} = integration) do
    SyncIcsCalendarWorker.enqueue(integration.id)
  end

  # EWS has no delta mode either: a refresh re-reads the whole window through
  # both of the provider's reads.
  def request_sync(%{provider: "exchange"} = integration) do
    %{"calendar_integration_id" => integration.id}
    |> SyncExchangeCalendarWorker.new()
    |> Oban.insert()
  end

  def request_sync(%{provider: provider} = integration) do
    if provider in @caldav_providers do
      # Manual refresh always forces a full fetch: users click Refresh because
      # they believe something is missing, and delta sync is exactly what would
      # miss it. See docs/superpowers/specs/2026-04-13-caldav-periodic-full-resync-design.md.
      SyncCalDavCalendarWorker.enqueue_full_fetch(integration.id)
    else
      {:error, "unknown provider: #{provider} for integration #{integration.id}"}
    end
  end
end
