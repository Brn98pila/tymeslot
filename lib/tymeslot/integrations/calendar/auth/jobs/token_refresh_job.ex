defmodule Tymeslot.Integrations.Calendar.TokenRefreshJob do
  @moduledoc """
  Background job for refreshing calendar OAuth tokens with intelligent retry strategy.

  This job runs periodically to refresh OAuth tokens that are about to expire,
  ensuring continuous access to calendar APIs for both Google and Outlook.

  The sweep, on the Oban crontab hourly, enqueues one job per integration
  whose token expires within the next two hours, starting at a random point
  in the next half hour and unique until it has finished (waiting, running,
  retrying or snoozed), and each job refreshes with that same window as its
  buffer, so a token is renewed ahead of expiry rather than by the first
  API call to find it expired. A token whose expiry moved on since the job
  read the integration was refreshed by someone else in the meantime (an API
  call, a connection test), and the job then does nothing. The refresh takes
  the same lock as every other refresh of the integration, so it never
  overlaps one.

  Overrides `c:Oban.Worker.backoff/1` with a schedule optimised for token refresh
  timing:
  - Fast initial retries for transient issues
  - Longer backoffs to avoid rate limiting
  - Takes advantage of 2-hour refresh buffer
  """

  use Oban.Worker,
    queue: :calendar_integrations,
    max_attempts: 8

  require Logger

  alias Tymeslot.Infrastructure.BreakerOutcome
  alias Tymeslot.Infrastructure.ExpectedJobOutcome
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Infrastructure.Logging.Redactor
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationWebhookQueries
  alias Tymeslot.Integrations.Calendar.Tokens
  alias Tymeslot.Integrations.CalendarManagement
  alias Tymeslot.Integrations.Shared.ReauthHandling
  alias Tymeslot.Workers.RetryHelpers

  @refresh_threshold_hours 2
  @lock_timeout_snooze_seconds 60
  @sweep_spread_seconds 1800

  @doc """
  Custom backoff strategy optimized for token refresh.

  Since we start refreshing 2 hours before expiration, we can afford
  longer backoffs to avoid rate limiting while still having plenty of buffer time.

  Oban's default would exhaust all eight attempts in roughly six minutes, abandoning
  the refresh with almost the whole buffer unused.
  """
  @impl Oban.Worker
  @spec backoff(Oban.Job.t()) :: non_neg_integer()
  def backoff(%Oban.Job{attempt: attempt}) do
    case attempt do
      # 1 second (network hiccup)
      1 -> 1
      # 3 seconds (quick retry)
      2 -> 3
      # 10 seconds (maybe temporary issue)
      3 -> 10
      # 5 minutes (avoid rate limits)
      4 -> 300
      # 15 minutes (longer cooldown)
      5 -> 900
      # 30 minutes (significant backoff)
      6 -> 1800
      # 1 hour (final attempt)
      7 -> 3600
      # Cap at 1 hour
      _other -> 3600
    end
  end

  @behaviour ExpectedJobOutcome

  # The integration is gone, or its grant expired and only the owner can
  # reconnect it. Any other refusal, such as `invalid_client`, points at the
  # OAuth client registration and is recorded.
  @integration_gone "Integration not found"

  @impl ExpectedJobOutcome
  def expected_outcome?(@integration_gone), do: true

  def expected_outcome?(reason) when is_binary(reason) do
    case String.split(reason, ReauthHandling.discard_reason(), parts: 2) do
      ["", ""] -> true
      ["", ": " <> cause] -> ReauthHandling.rejection_cause(cause) == :expired_grant
      _other -> false
    end
  end

  def expected_outcome?(_reason), do: false

  @impl Oban.Worker
  def perform(%Oban.Job{
        id: job_id,
        attempt: attempt,
        args: %{"integration_id" => integration_id}
      }) do
    # Single integration refresh (for retry jobs)
    case CalendarIntegrationQueries.get(integration_id) do
      {:error, :not_found} ->
        {:discard, @integration_gone}

      {:error, :requires_reencryption, integration} ->
        CalendarManagement.handle_reauth_required(integration)

      {:ok, integration} ->
        refresh_integration_token(integration, job_id: job_id, attempt: attempt)
    end
  end

  def perform(%Oban.Job{}) do
    # Bulk refresh for periodic job
    refresh_expiring_tokens()
  end

  @spec refresh_expiring_tokens() :: :ok | {:error, term()}
  defp refresh_expiring_tokens do
    threshold = DateTime.add(DateTime.utc_now(), @refresh_threshold_hours, :hour)

    # Refresh Google Calendar tokens
    Enum.each(
      CalendarIntegrationWebhookQueries.list_expiring_google_tokens(threshold),
      &schedule_individual_refresh/1
    )

    # Refresh Outlook Calendar tokens
    Enum.each(
      CalendarIntegrationWebhookQueries.list_expiring_outlook_tokens(threshold),
      &schedule_individual_refresh/1
    )

    :ok
  end

  # One job per integration until it has finished, however long that takes:
  # a sweep must not enqueue a second refresh for a token whose first is still
  # waiting, running, retrying or snoozed, as each one is a real token request.
  # The start is spread over half an hour so a sweep does not land every
  # refresh on the queue's few slots at once.
  defp schedule_individual_refresh(%CalendarIntegrationSchema{id: id}) do
    %{"integration_id" => id}
    |> new(
      schedule_in: :rand.uniform(@sweep_spread_seconds),
      unique: [
        keys: [:integration_id],
        period: :infinity,
        states: [:available, :scheduled, :executing, :retryable]
      ]
    )
    |> Oban.insert()
  end

  # Private functions

  defp refresh_integration_token(
         %CalendarIntegrationSchema{provider: provider} = integration,
         job_meta
       ) do
    meta = Keyword.merge(job_meta, user_id: integration.user_id)

    result =
      Tokens.refresh_oauth_token(integration, buffer_seconds: @refresh_threshold_hours * 3600)

    log_failure(result, integration, meta)

    case result do
      {:ok, _updated_integration} ->
        # Tokens.refresh_oauth_token handles persistence already
        :ok

      {:error, :lock_timeout} ->
        # Another refresh of this integration held the lock for longer than
        # the wait. Come back once it has finished: by then the token is
        # either refreshed, and this job does nothing, or still due.
        Logger.info(
          "Token refresh deferred: another refresh holds the lock",
          Keyword.merge(meta, integration_id: integration.id, provider: provider)
        )

        {:snooze, @lock_timeout_snooze_seconds}

      {:error, :integration_not_found} ->
        # Deleted after `perform/1` read it; there is nothing left to refresh,
        # and nothing to write a failure to.
        {:discard, @integration_gone}

      {:error, :requires_reencryption} ->
        # The row stopped decrypting after `perform/1` read it. Tokens has
        # already flagged it, so there is nothing left to retry.
        {:discard, ReauthHandling.discard_reason()}

      {:error, {type, msg}} ->
        handle_refresh_error(integration, "#{type}: #{msg}", provider)

      {:error, reason} ->
        handle_refresh_error(integration, reason, provider)
    end
  end

  defp handle_refresh_error(integration, reason, provider) do
    case categorize_error(reason) do
      :permanent ->
        # Only the owner can fix this, so ask them to reconnect rather than
        # deactivating: a deactivated integration reads as paused on the
        # dashboard, sends no email, and drops out of the health probe that
        # could otherwise correct the verdict.
        #
        # The discard reason is what an operator sees on the job record, so it
        # carries the OAuth error code: `invalid_grant` and `invalid_client`
        # point at different things (the owner's account, our client
        # registration) and the flag alone cannot tell them apart.
        with {:discard, message} <-
               CalendarManagement.handle_reauth_required(integration,
                 cause: ReauthHandling.rejection_cause(reason)
               ) do
          {:discard, "#{message}: #{reason}"}
        end

      :rate_limited ->
        # Respect rate limiting with custom backoff
        retry_after = RetryHelpers.parse_retry_after_from_message(reason) || 300

        error_msg = refresh_failure_message(provider, "#{reason} (RATE_LIMITED)")

        persist_refresh_failure(integration, error_msg)

        {:snooze, retry_after}

      :retryable ->
        # Let Oban handle retry with our custom backoff
        error_msg = refresh_failure_message(provider, "#{reason} (RETRYABLE)")

        persist_refresh_failure(integration, error_msg)

        {:error, "#{reason}"}
    end
  end

  # The provider's error body never reaches here, but a reason can quote one,
  # so it is redacted like any other provider text.
  defp log_failure({:ok, _integration}, _integration_row, _meta), do: :ok

  defp log_failure({:error, reason}, integration, meta) do
    Logger.warning(
      "Calendar token refresh failed",
      Keyword.merge(meta,
        integration_id: integration.id,
        provider: integration.provider,
        reason: Redactor.redact(LogFormat.reason(reason))
      )
    )
  end

  # The wording is part of the stored `sync_error`, which a repair migration
  # (`ReactivateCalendarsDeactivatedByTokenRefresh`) matches on.
  defp refresh_failure_message(provider, reason),
    do: "#{String.capitalize(provider)} integration failed during token refresh: #{reason}"

  # A flagged integration's `sync_error` already carries the reason the owner
  # needs to act on (no calendar selected, deleted booking calendar, expired
  # grant). A refresh failure diagnostic is a different, unrelated cause
  # hitting the same field, so it must not clobber that reason.
  defp persist_refresh_failure(%{needs_reauth: true}, _error_msg), do: :ok

  defp persist_refresh_failure(integration, error_msg) do
    CalendarIntegrationQueries.update(integration, %{sync_error: error_msg})
  end

  # `:permanent` means "the provider refused the credential and only the owner
  # can fix it": it flags the integration and sends a reconnection email that
  # cannot be recalled. So the verdict comes from the OAuth error code the
  # provider returned, matched as a whole word by the same rule the breaker
  # and the health check use (`BreakerOutcome.permanent_credential_error?/1`).
  # A substring match on "unauthorized" is not that: every token-endpoint
  # refusal reaches here as `"unauthorized: Token refresh failed: ..."`, so it
  # would treat an unparseable 400 body, `invalid_request` or
  # `unsupported_grant_type` as a revoked grant.
  #
  # A refreshed token that failed to persist, or our own provider
  # misconfiguration, is a failure on our side: retrying it is cheap and
  # telling the owner their credentials were rejected would be wrong.
  defp categorize_error(:missing_credentials), do: :permanent
  defp categorize_error(reason) when is_atom(reason), do: categorize_error(Atom.to_string(reason))

  defp categorize_error(reason) when is_binary(reason) do
    cond do
      BreakerOutcome.permanent_credential_error?(reason) -> :permanent
      rate_limited_error?(reason) -> :rate_limited
      true -> :retryable
    end
  end

  defp categorize_error(_reason), do: :retryable

  defp rate_limited_error?(reason) do
    reason_lower = String.downcase(reason)
    Enum.any?(["rate_limited", "too_many_requests", "quota"], &String.contains?(reason_lower, &1))
  end
end
