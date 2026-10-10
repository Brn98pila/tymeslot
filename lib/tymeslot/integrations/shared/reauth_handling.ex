defmodule Tymeslot.Integrations.Shared.ReauthHandling do
  @moduledoc """
  Shared handler for the paths that end in "the user has to reconnect".

  The original caller was the "credentials no longer decrypt" path: when a
  query module returns `{:error, :requires_reencryption, integration}`, callers
  delegate here to log a warning, flag the integration for reauthentication,
  and return a normalised result. Permanent OAuth failures (an expired or
  revoked grant, credentials the provider now rejects) share the same
  side-effects but not the same diagnosis, so the reason is carried explicitly
  as a `t:cause/0`.

  Two distinct return shapes are available depending on context:

  - `flag/3` — returns `:ok | {:error, reason}`. Suitable for non-Oban
    callers (fetch helpers, token refreshers) that just want the side-effect
    and a simple success/failure signal.

  - Oban workers that need `{:discard, _} | {:error, _}` build that shape
    themselves on top of `flag/3`, typically via the
    `CalendarManagement.handle_reauth_required/2` or
    `Video.handle_reauth_required/2` wrappers.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Emails.EmailScheduler.IntegrationScheduler
  alias Tymeslot.Infrastructure.BreakerOutcome
  alias Tymeslot.Infrastructure.ErrorTracking
  alias Tymeslot.Integrations.Shared.IntegrationTypes
  alias Tymeslot.Repo

  require Logger

  @typedoc """
  Why the integration needs reconnecting.

  * `:credentials_undecryptable` — the stored ciphertext no longer decrypts
    under the current encryption key.
  * `:expired_grant` — the OAuth grant has expired or the user revoked it.
  * `:rejected_credentials` — the provider rejected the credentials for some
    other permanent reason (`invalid_client`, `access_denied`, a bare 401).
  * `:rejected_subscription_url` — a published calendar feed rejected the
    stored subscription link (401/403), which means it was revoked or
    rotated rather than that any credentials expired.
  """
  @type cause ::
          :credentials_undecryptable
          | :expired_grant
          | :rejected_credentials
          | :rejected_subscription_url

  @default_cause :credentials_undecryptable

  @discard_reason "Credentials require reauthentication"

  # One row per cause: the operator-facing log line and the message persisted
  # to the integration's `sync_error`, which the account owner reads. Keeping
  # them together stops the two from drifting, and stops a decryption
  # diagnosis being reused for an OAuth failure it does not describe.
  #
  # `message` is persisted as its English msgid, never translated here: the
  # flagging process's locale belongs to whoever happened to trigger the flag,
  # not to the owner who reads it. The dashboard translates it into the
  # viewer's locale when it renders (`ConnectionLabels.reconnect_reason/1`).
  @causes %{
    credentials_undecryptable: %{
      log: "Integration credentials cannot be decrypted — flagging for reauth",
      message:
        dgettext_noop(
          "dashboard_integrations",
          "Stored credentials could not be decrypted with the current encryption key. Please reconnect the integration."
        )
    },
    expired_grant: %{
      log: "Integration authorisation has expired or been revoked — flagging for reauth",
      message:
        dgettext_noop(
          "dashboard_integrations",
          "Access to the connected account has expired or been revoked. Please reconnect the integration."
        )
    },
    rejected_credentials: %{
      log: "Integration credentials were rejected by the provider — flagging for reauth",
      message:
        dgettext_noop(
          "dashboard_integrations",
          "The provider rejected the stored credentials for this integration. Please reconnect the integration."
        )
    },
    rejected_subscription_url: %{
      log: "Calendar subscription feed rejected the stored link — flagging for reauth",
      message:
        dgettext_noop(
          "dashboard_integrations",
          "The calendar feed rejected the stored link. It was probably revoked or reset — subscribe again with a fresh URL."
        )
    }
  }

  @doc """
  The error message recorded when flagging an integration for reauth for the
  given `t:cause/0`: the untranslated msgid, exactly as persisted to
  `sync_error`.

  Exposed so tests can pin the persisted message without restating the copy.
  """
  @spec reauth_error_message(cause()) :: String.t()
  def reauth_error_message(cause), do: fetch_cause(cause).message

  @doc """
  The reason an Oban job is discarded with once its integration has been
  flagged for reauthentication. Only the owner can fix that, so workers
  declare it an expected outcome (`Tymeslot.Infrastructure.ExpectedJobOutcome`).
  """
  @spec discard_reason() :: String.t()
  def discard_reason, do: @discard_reason

  @doc """
  Which `t:cause/0` a permanent credential failure describes.

  `invalid_grant` and `:token_expired` mean the grant itself is gone: expired,
  or revoked by the user in their provider account. Anything else the provider
  refused counts as rejected credentials. The two get different messages
  because they send the owner to different places.

  A binary reason is matched on whole-word tokens, so the marker has to reach
  this function intact: a caller that replaces the provider's error text with
  its own wording loses the distinction.
  """
  @spec rejection_cause(term()) :: :expired_grant | :rejected_credentials
  def rejection_cause(:token_expired), do: :expired_grant

  def rejection_cause(reason) when is_binary(reason) do
    if "invalid_grant" in BreakerOutcome.error_tokens(reason),
      do: :expired_grant,
      else: :rejected_credentials
  end

  def rejection_cause({:exception, message}) when is_binary(message),
    do: rejection_cause(message)

  def rejection_cause(_reason), do: :rejected_credentials

  @doc """
  Flags an integration of `kind` for reauthentication with the diagnosis of
  `cause` (a `t:cause/0`, `:credentials_undecryptable` by default), through
  `flag_and_notify/3`.

  Returns `{:error, :not_found}` when the integration's row is gone, and
  `{:error, :notification_failed}` when nothing was flagged because the email
  could not be queued.
  """
  @spec flag(IntegrationTypes.kind(), struct(), cause()) ::
          :ok | {:error, :not_found | :notification_failed}
  def flag(kind, integration, cause \\ @default_cause) do
    cause_key = cause_key(cause)
    %{log: log, message: message} = fetch_cause(cause_key)
    log_name = IntegrationTypes.log_name(kind)

    if cause_key == :credentials_undecryptable,
      do: report_undecryptable(integration, log_name)

    Logger.warning(log,
      integration_type: log_name,
      provider: integration.provider,
      integration_id: integration.id,
      user_id: integration.user_id
    )

    with {:ok, _updated} <- flag_and_notify(kind, integration, message), do: :ok
  end

  @doc """
  Marks an integration of `kind` `needs_reauth` with `message` (an untranslated
  msgid, see `t:cause/0`) as its sync error, and emails the owner when this
  is a new flag.

  Only a false to true transition is news: re-flagging an integration the
  owner has already been told about would email them again about a problem
  they are already looking at. The transition is decided by the row, so of
  two flaggers holding the same stale struct only one sends the email.

  The flag and the email job commit together. Every later flag reads the row
  as already flagged, so a flag that committed without its email would leave
  the owner never told; if the job cannot be inserted, the flag is rolled
  back and `{:error, :notification_failed}` returned, for the caller to retry.
  """
  @spec flag_and_notify(IntegrationTypes.kind(), struct(), String.t()) ::
          {:ok, struct()} | {:error, :not_found | :notification_failed}
  def flag_and_notify(kind, integration, message) do
    Repo.transaction(fn ->
      case IntegrationTypes.queries(kind).flag_needs_reauth(integration, message) do
        {:ok, updated, true} -> notify(kind, updated)
        {:ok, updated, false} -> updated
        {:error, :not_found} -> Repo.rollback(:not_found)
      end
    end)
    |> tap(fn
      {:error, :not_found} ->
        Logger.warning("Integration to flag for reauth no longer exists",
          integration_type: IntegrationTypes.log_name(kind),
          integration_id: integration.id
        )

      _result ->
        :ok
    end)
  end

  # A uniqueness conflict is reported as :ok: an email for this flag is
  # already queued.
  defp notify(kind, updated) do
    case IntegrationScheduler.schedule_integration_reauth_notification(
           %{id: updated.user_id},
           updated,
           kind
         ) do
      :ok -> updated
      {:error, _reason} -> Repo.rollback(:notification_failed)
    end
  end

  defp cause_key(cause) when is_map_key(@causes, cause), do: cause
  defp cause_key(_unknown), do: @default_cause

  defp fetch_cause(cause), do: Map.fetch!(@causes, cause_key(cause))

  # Credentials that no longer decrypt usually mean the encryption key was
  # lost or rotated: the operator's to fix, and never one integration's
  # alone. The job that meets them is discarded as an expected end, since
  # only a reconnect recovers that integration, so the failure is recorded
  # here instead. One call site and one reason, so however many
  # integrations are affected it is one error, and one new-error alert.
  defp report_undecryptable(integration, log_name) do
    ErrorTracking.report_error(:credentials_undecryptable, nil, %{
      integration_type: log_name,
      provider: integration.provider,
      integration_id: integration.id,
      user_id: integration.user_id
    })
  end
end
