defmodule Tymeslot.Integrations.CalendarManagement do
  @moduledoc """
  Context for calendar integration CRUD operations.

  Handles creation, reading, updating, and deletion of calendar integrations,
  separated from primary calendar logic and discovery operations.
  """

  alias Tymeslot.Emails.EmailScheduler.IntegrationScheduler
  alias Tymeslot.Integrations.Calendar.Blocking
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.CalendarPreferencesQueries
  alias Tymeslot.Integrations.Calendar.Defaults
  alias Tymeslot.Integrations.Calendar.Discovery
  alias Tymeslot.Integrations.Calendar.PrimaryElection
  alias Tymeslot.Integrations.HealthCheck
  alias Tymeslot.Integrations.Shared.ReauthHandling
  alias Tymeslot.Repo
  require Logger

  @type user_id :: integer()
  @type integration_id :: integer()
  @type integration_attrs :: map()

  @doc """
  Lists all calendar integrations for a user.
  """
  @spec list_calendar_integrations(user_id()) :: [CalendarIntegrationSchema.t()]
  def list_calendar_integrations(user_id) do
    CalendarIntegrationQueries.list_all_for_user(user_id)
  end

  @doc """
  Lists the user's active calendar integrations whose credentials can be read,
  decrypted.

  An integration whose credentials no longer decrypt is left out and flagged
  for reconnection; see `partition_active_calendar_integrations/1`.
  """
  @spec list_active_calendar_integrations(user_id()) :: [CalendarIntegrationSchema.t()]
  def list_active_calendar_integrations(user_id) do
    {readable, _unreadable} = partition_active_calendar_integrations(user_id)
    readable
  end

  @doc """
  Splits the user's active calendar integrations into those whose credentials
  can be read, decrypted, and those whose credentials no longer decrypt (a
  changed key, a corrupt row), as stored.

  Each unreadable integration not already awaiting reconnection is flagged for
  it, which also tells the owner. The caller decides what an unreadable one
  means: the availability check treats it as a calendar it could not read.
  """
  @spec partition_active_calendar_integrations(user_id()) ::
          {[CalendarIntegrationSchema.t()], [CalendarIntegrationSchema.t()]}
  def partition_active_calendar_integrations(user_id) do
    user_id
    |> CalendarIntegrationQueries.list_active_for_user()
    |> decrypt_or_flag()
  end

  @doc """
  The user's calendar display preferences. Returns the stored row if one
  exists, otherwise an unsaved struct populated with defaults — callers that
  need the defaults persisted must call `save_preferences/2` themselves.
  """
  @spec get_or_create_preferences(user_id()) :: struct()
  def get_or_create_preferences(user_id) do
    CalendarPreferencesQueries.get_or_create(user_id)
  end

  @doc """
  Upserts the user's calendar display preferences.
  """
  @spec save_preferences(user_id(), map()) :: {:ok, struct()} | {:error, Ecto.Changeset.t()}
  def save_preferences(user_id, attrs) do
    CalendarPreferencesQueries.upsert(user_id, attrs)
  end

  @doc """
  Gets a single calendar integration, returning a two-outcome tuple.

  Delegates to `fetch_integration_for_user/2` so that a
  `{:error, :requires_reencryption, _}` result is silently flagged and
  collapsed to `{:error, :not_found}` before it reaches callers.
  """
  @spec get_calendar_integration(integration_id(), user_id()) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, :not_found}
  def get_calendar_integration(integration_id, user_id) do
    fetch_integration_for_user(integration_id, user_id)
  end

  @doc """
  Fetches a calendar integration by ID for a user, collapsing the
  `{:error, :requires_reencryption, integration}` arm into `{:error, :not_found}`
  after silently flagging the integration for reauthentication.

  Use this in non-Oban callers that only care about the two-outcome
  `{:ok, _} | {:error, :not_found}` shape.
  """
  @spec fetch_integration_for_user(integration_id(), user_id()) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, :not_found}
  def fetch_integration_for_user(integration_id, user_id) do
    case CalendarIntegrationQueries.get_for_user(integration_id, user_id) do
      {:ok, integration} ->
        {:ok, integration}

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, :requires_reencryption, stale} ->
        flag_for_reauth(stale)
        {:error, :not_found}
    end
  end

  @doc """
  Creates a new calendar integration.
  Automatically sets as primary if it's the user's first calendar.

  A CalDAV-family integration is refused with `{:error, %{discovery: message}}`
  when there is nothing for it to sync — see
  `Tymeslot.Integrations.Calendar.Discovery.maybe_discover_calendars/1`, which
  resolves the calendar selection before anything is written.
  """
  @spec create_calendar_integration(integration_attrs()) ::
          {:ok, CalendarIntegrationSchema.t()}
          | {:error, Ecto.Changeset.t() | %{discovery: String.t()}}
  def create_calendar_integration(attrs) do
    with {:ok, discovered_attrs} <- Discovery.maybe_discover_calendars(attrs),
         {:ok, integration} <- insert_integration(discovered_attrs),
         {:ok, final_integration} <- ensure_default_booking_calendar(integration) do
      :telemetry.execute([:tymeslot, :calendar, :connected], %{count: 1}, %{
        provider: final_integration.provider
      })

      {:ok, final_integration}
    else
      other -> other
    end
  end

  @doc """
  Inserts an integration and, when it is bookable and its user has no active
  primary calendar, makes it the primary, both under the primary lock (see
  `Tymeslot.Integrations.Calendar.PrimaryElection`). For every path that
  creates an integration, including an OAuth callback, which has already
  resolved its calendars.
  """
  @spec insert_integration(%{required(:user_id) => user_id(), optional(atom()) => term()}) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def insert_integration(%{user_id: user_id} = attrs) do
    PrimaryElection.under_lock(user_id, fn ->
      case CalendarIntegrationQueries.create(attrs) do
        {:ok, integration} ->
          PrimaryElection.adopt_if_vacant(integration)
          integration

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  @doc """
  Toggle an integration and rebalance the user's primary calendar atomically.
  Ensures that primary rules are preserved even under concurrent updates.

  Reactivating clears the health state row and enqueues an immediate probe so
  the badge can't lie about an integration the user has just turned back on.
  """
  @spec toggle_with_primary_rebalance(CalendarIntegrationSchema.t()) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, any()}
  def toggle_with_primary_rebalance(%CalendarIntegrationSchema{} = integration) do
    integration
    |> transactional_toggle()
    |> maybe_mark_recovered()
  end

  @doc """
  Pauses an active integration: sets it inactive, never the other way round,
  and when it was the user's primary calendar elects the next one (see
  `Tymeslot.Integrations.Calendar.PrimaryElection`), under the same lock as
  a user's own toggle. For the system pausing an unhealthy integration.

  An integration already inactive stays inactive.
  """
  @spec pause_integration(CalendarIntegrationSchema.t()) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, any()}
  def pause_integration(%CalendarIntegrationSchema{} = integration) do
    PrimaryElection.under_lock(integration.user_id, fn ->
      primary_id = PrimaryElection.stored_primary_id(integration.user_id)

      # Only ever `false`: whatever the struct says, this never activates.
      case deactivate_stored(integration) do
        {:ok, %{id: id, user_id: user_id} = paused} when id == primary_id ->
          PrimaryElection.elect_next(user_id, [id])
          paused

        {:ok, paused} ->
          paused

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  defp transactional_toggle(integration) do
    PrimaryElection.under_lock(integration.user_id, fn ->
      current_primary_id = PrimaryElection.stored_primary_id(integration.user_id)

      case toggle_stored(integration) do
        {:ok, updated} ->
          maybe_rebalance_primary(updated, current_primary_id)
          updated

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  # Under the lock, the struct handed in may be older than the row: toggled
  # since, or deleted. Both act on the row as it stands.
  defp toggle_stored(integration) do
    case CalendarIntegrationQueries.reload(integration) do
      nil -> {:error, :not_found}
      stored -> CalendarIntegrationQueries.toggle_active(stored)
    end
  end

  defp deactivate_stored(integration) do
    case CalendarIntegrationQueries.reload(integration) do
      nil -> {:error, :not_found}
      stored -> CalendarIntegrationQueries.deactivate(stored)
    end
  end

  # Marking recovery is deliberately outside the transaction above: it enqueues
  # an Oban probe, which must not be rolled back with the toggle if a later
  # step in the same transaction were ever added and failed.
  defp maybe_mark_recovered({:ok, %{is_active: true} = updated} = ok) do
    HealthCheck.mark_user_recovered(:calendar, updated.id)
    ok
  end

  defp maybe_mark_recovered(result), do: result

  @doc """
  Updates a calendar integration.

  When the attrs carry credentials — i.e. the owner has supplied fresh ones via
  a reconnect form — `needs_reauth` is cleared, the integration's health state
  row is reset, and an immediate verification probe is enqueued so the in-app
  badge clears without waiting up to an hour for the next scheduled probe.
  """
  @spec update_calendar_integration(CalendarIntegrationSchema.t(), integration_attrs()) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def update_calendar_integration(integration, attrs) do
    if credentials_in_attrs?(attrs) do
      update_with_credentials(integration, attrs)
    else
      CalendarIntegrationQueries.update(integration, attrs)
    end
  end

  defp update_with_credentials(integration, attrs) do
    with {:ok, updated} = ok <- CalendarIntegrationQueries.update_credentials(integration, attrs) do
      HealthCheck.mark_user_recovered(:calendar, updated.id)
      ok
    end
  end

  @doc """
  Flags an integration as needing reauthentication when its stored credentials
  can no longer be decrypted. Also records the sync error so the dashboard
  shows the same message the worker logged.
  """
  @spec mark_needs_reauth(CalendarIntegrationSchema.t(), String.t()) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, Ecto.Changeset.t()}
  def mark_needs_reauth(integration, error_message) do
    CalendarIntegrationQueries.mark_needs_reauth(integration, error_message)
  end

  @doc """
  Entry point for the "credentials no longer decrypt" path, used by any
  worker or caller that receives `{:error, :requires_reencryption, integration}`
  from `CalendarIntegrationQueries.get/1`.

  Pass `cause: cause` (see `t:Tymeslot.Integrations.Shared.ReauthHandling.cause/0`)
  when the integration needs reconnecting for a different reason, so the message
  recorded on `sync_error` describes what actually failed.

  Returns an Oban return value: `{:discard, _}` on success (retrying won't
  recover the credentials), or `{:error, _}` if the flag couldn't be persisted —
  which causes Oban to retry the job and take another shot at recording the flag.
  """
  @spec handle_reauth_required(CalendarIntegrationSchema.t(), keyword()) ::
          {:discard, String.t()} | {:error, String.t()}
  def handle_reauth_required(%CalendarIntegrationSchema{} = integration, opts \\ []) do
    case flag_for_reauth(integration, opts) do
      :ok -> {:discard, ReauthHandling.discard_reason()}
      {:error, _changeset} -> {:error, "Failed to flag integration for reauth"}
    end
  end

  @doc """
  Flags an integration for reconnection and returns the Oban value a worker
  should return, for failures only the owner can resolve: a deleted booking
  calendar, or credentials the provider now rejects.

  `message` is the explanation shown on the dashboard, passed as its
  untranslated msgid (mark it with `dgettext_noop/2` in the
  `dashboard_calendar_providers` or `dashboard_integrations` domain) so the
  dashboard can translate it into the viewer's locale;
  `discard_reason` is the operator-facing reason recorded on the job.

  Discarding rather than returning `{:error, _}` is the point. Retrying re-asks
  a question already answered, and an exhausted retry chain raises a
  permanent-failure admin alert about a condition no operator can fix.
  A failed *flag write* is worth retrying, though: without it the owner is
  never told why their calendar stopped syncing.

  The first flag also emails the owner a reconnection notice carrying
  `message`; re-flagging an integration already awaiting reconnection does not.
  """
  @spec flag_for_reconnection(CalendarIntegrationSchema.t(), String.t(), String.t()) ::
          {:discard, String.t()} | {:error, String.t()}
  def flag_for_reconnection(%CalendarIntegrationSchema{} = integration, message, discard_reason) do
    case flag_and_notify(integration, message) do
      {:ok, _updated} -> {:discard, discard_reason}
      {:error, _changeset} -> {:error, "Failed to flag integration: #{discard_reason}"}
    end
  end

  # Only a false → true transition is news. Re-flagging an integration the owner
  # has already been told about would email them again about a problem they are
  # already looking at; the scheduler's uniqueness window is a backstop for
  # that, not the place to decide it.
  defp flag_and_notify(%{needs_reauth: true} = integration, message),
    do: mark_needs_reauth(integration, message)

  # The badge alone reaches only owners who open the dashboard. Everyone else
  # discovers a dead calendar when a booking needs it, which is too late, so
  # flagging and notifying are one step and cannot come apart.
  defp flag_and_notify(integration, message) do
    with {:ok, updated} = result <- mark_needs_reauth(integration, message) do
      IntegrationScheduler.schedule_integration_reauth_notification(
        %{id: updated.user_id},
        updated,
        :calendar
      )

      result
    end
  end

  # Shared helper: delegates to ReauthHandling.flag/2 with calendar-specific
  # opts. `mark_needs_reauth` is wired to `flag_and_notify/2` rather than the
  # bare DB write, so that every path ending in "the owner has to reconnect",
  # this one included and not just `flag_for_reconnection/3`, sends the reauth
  # email on the false to true transition. See the deferred ticket this closed
  # for why the two calendar entry points used to disagree on that.
  defp flag_for_reauth(integration, opts \\ []) do
    ReauthHandling.flag(
      integration,
      Keyword.merge(
        [mark_needs_reauth: &flag_and_notify/2, log_prefix: "Calendar"],
        opts
      )
    )
  end

  # Only an integration not yet flagged is flagged here: these listings run on
  # every booking page load, and re-flagging reports the same undecryptable
  # row to error tracking each time.
  defp decrypt_or_flag(integrations) do
    {readable, unreadable} =
      Enum.split_with(
        integrations,
        &(CalendarIntegrationSchema.decryption_status(&1) == :ok)
      )

    unreadable
    |> Enum.reject(& &1.needs_reauth)
    |> Enum.each(&flag_for_reauth/1)

    {Enum.map(readable, &CalendarIntegrationSchema.decrypt_credentials/1), unreadable}
  end

  # Callers supply the virtual field names (`:password`), never the encrypted
  # ones — those only exist after `encrypt_credentials/1` runs inside the
  # changeset, by which point the attrs have already been consumed.
  defp credentials_in_attrs?(attrs) when is_map(attrs) do
    fields = CalendarIntegrationSchema.credential_fields()

    Enum.any?(fields, fn f -> Map.has_key?(attrs, f) or Map.has_key?(attrs, Atom.to_string(f)) end)
  end

  # Private helpers

  defp ensure_default_booking_calendar(%{default_booking_calendar_id: nil} = integration) do
    # Only set a default booking calendar automatically if the user doesn't
    # already have one (to satisfy the unique_booking_calendar_per_user constraint
    # and keep the existing primary unchanged when adding more integrations).
    if has_existing_default?(integration.user_id) do
      {:ok, integration}
    else
      set_default_booking_calendar(integration)
    end
  end

  defp ensure_default_booking_calendar(integration), do: {:ok, integration}

  defp has_existing_default?(user_id) do
    CalendarIntegrationQueries.user_has_default_booking_calendar?(user_id)
  end

  defp set_default_booking_calendar(integration) do
    case Defaults.resolve_default_calendar_id(integration) do
      nil ->
        {:ok, integration}

      default_id ->
        update_default_booking_calendar(integration, default_id)
    end
  end

  # The booking calendar must block availability, so storing one makes it
  # block in the same write (see `Blocking`).
  defp update_default_booking_calendar(integration, default_id) do
    case Blocking.set_default_booking_calendar(integration, default_id) do
      {:ok, updated} ->
        {:ok, updated}

      {:error, %Ecto.Changeset{} = changeset} ->
        handle_booking_calendar_update_error(integration, changeset)
    end
  end

  defp handle_booking_calendar_update_error(integration, changeset) do
    if unique_booking_calendar_conflict?(changeset) do
      # If the unique constraint is hit (another integration already has a default),
      # keep the existing primary/default and proceed without error.
      {:ok, integration}
    else
      Logger.error("Failed to set default booking calendar",
        user_id: integration.user_id,
        integration_id: integration.id,
        errors: changeset.errors
      )

      {:error, changeset}
    end
  end

  defp unique_booking_calendar_conflict?(%Ecto.Changeset{} = changeset) do
    Enum.any?(changeset.errors, fn
      {:default_booking_calendar_id, {_msg, opts}} ->
        opts[:constraint] == :unique &&
          to_string(opts[:constraint_name]) == "unique_booking_calendar_per_user"

      _other ->
        false
    end)
  end

  defp maybe_rebalance_primary(%{is_active: false, id: id, user_id: uid}, current_primary_id)
       when current_primary_id == id do
    PrimaryElection.elect_next(uid, [id])
    :ok
  end

  defp maybe_rebalance_primary(%{is_active: true} = updated, _current_primary_id) do
    PrimaryElection.adopt_if_vacant(updated)
    :ok
  end

  defp maybe_rebalance_primary(_updated, _current_primary_id), do: :ok

  @doc """
  Writes the tokens an OAuth reconnect has just proved and activates the
  integration, then adopts it as the user's primary calendar when they have
  no active one, all under the primary lock, so every activation is decided
  there (see `Tymeslot.Integrations.Calendar.PrimaryElection`).

  Acts on the row as it stands. Reactivating a paused row is refused with
  `{:error, :duplicate_account}` when another active integration already uses
  the same account, as switching it back on would be. Call it after the
  provider round trip, never around one, so the lock is not held across HTTP.
  """
  @spec reconnect_integration(CalendarIntegrationSchema.t(), integration_attrs()) ::
          {:ok, CalendarIntegrationSchema.t()}
          | {:error, :not_found | :duplicate_account | Ecto.Changeset.t()}
  def reconnect_integration(%CalendarIntegrationSchema{} = integration, attrs) do
    PrimaryElection.under_lock(integration.user_id, fn ->
      with {:ok, stored} <- stored_for_reconnect(integration),
           :ok <- reactivation_allowed(stored, attrs),
           {:ok, updated} <- update_calendar_integration(stored, attrs) do
        if updated.is_active, do: PrimaryElection.adopt_if_vacant(updated)
        updated
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  # Decrypted when it can be, so the reconnected struct still carries any
  # credential the provider did not send again; as stored when it cannot,
  # since a reconnect is how an unreadable integration is repaired.
  defp stored_for_reconnect(%{id: id}) do
    case CalendarIntegrationQueries.get(id) do
      {:ok, integration} -> {:ok, integration}
      {:error, :requires_reencryption, stored} -> {:ok, stored}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  defp reactivation_allowed(%{is_active: false} = stored, %{is_active: true}),
    do: CalendarIntegrationQueries.check_reactivation_conflict(stored)

  defp reactivation_allowed(_stored, _attrs), do: :ok
end
