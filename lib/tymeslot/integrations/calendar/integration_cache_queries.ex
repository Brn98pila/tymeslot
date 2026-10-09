defmodule Tymeslot.Integrations.Calendar.IntegrationCacheQueries do
  @moduledoc """
  The lock every write to an integration's cached events takes, the bulk
  replacement a full refresh makes under it, and the cache's housekeeping.

  ## The integration cache lock

  A transaction-scoped advisory lock of class `2`
  (`@integration_cache_lock_class`), keyed on the calendar integration's id. Every write to that integration's
  rows in `provider_calendar_events` takes it first, through `lock/1` or
  `under_lock/2`: a full refresh (`replace_cached_rows/3`), a sync's upsert
  (`Tymeslot.Integrations.Calendar.Sync.upsert_cache/2`) and the CalDAV
  reconciler's atomic upsert-and-delete. Two writes to one integration's
  cache therefore never interleave, and a delete-and-reinsert is never seen
  half done.

  ## Lock order

  `provider_calendar_events` has two foreign keys, and a row written with
  either set takes a key-share lock on the row it names:

    * `calendar_integration_id` → `calendar_integrations` (`ON DELETE CASCADE`);
    * `video_integration_id` → `video_integrations` (`ON DELETE SET NULL`).
      A sync sets it when it hands a replaced series master's room to the
      series' occurrences (`ProviderCalendarSeriesQueries.put_video/5`).

  A deletion of either parent locks the parent row first and then reaches
  the event rows (by cascade or by nulling the column). A write that locked
  event rows first and the parent row second would deadlock against it, so
  `lock/1` takes, in this order and before any event row:

    1. the integration cache lock (advisory, class `2`, the integration id);
    2. the calendar integration row, `FOR KEY SHARE`;
    3. the owner's video integration rows, `FOR KEY SHARE`, in id order;

  and only then does the write touch `provider_calendar_events`.

  The paths that lock an integration row for themselves take it before
  touching event rows, so they either finish before a cache write gets its
  key-share locks or wait behind it:

    * deleting a calendar integration (`Calendar.Deletion`) takes the cache
      lock, then `PrimaryElection.under_lock/3`'s profile and integration
      rows, then cascades into the events;
    * deleting an account (`Auth.AccountDeletion`) takes the cache lock of
      every calendar integration the user has, in id order, before it locks
      or deletes the user row, whose cascade reaches the calendar and video
      integrations and from them the events;
    * deleting a video integration locks its row, then nulls the column on
      event rows; a cache write either holds the key-share lock already
      (the delete waits) or has not yet touched an event row;
    * a toggle, a pause, a reconnect and a change of primary lock the
      profile and integration rows (`PrimaryElection.under_lock/3`) and
      update the integration row, never an event row, and take no advisory
      lock: a cache write waits for them at step 2 while holding only step 1.

  A cache write that finds its integration gone at step 2 (deleted while it
  waited) answers `{:error, :integration_gone}` and writes nothing.
  """

  import Ecto.Query, warn: false

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.EventRole
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Integrations.Video.VideoIntegrationSchema
  alias Tymeslot.Repo

  @integration_cache_lock_class 2
  @roles EventRole.all()

  @typedoc "Which of an integration's rows a full refresh replaces: all, or one role's."
  @type scope :: :all | {:role, String.t()}

  @doc """
  Takes the integration cache lock for `calendar_integration_id`, in the
  order the module doc gives. Call it inside a transaction, before the
  transaction touches any of the integration's cached rows; the locks are
  released when it ends. Taking it again in the same transaction is a no-op.
  """
  @spec lock(pos_integer()) :: :ok | {:error, :integration_gone}
  def lock(calendar_integration_id) do
    lock_cache_class(calendar_integration_id)

    owner =
      Repo.one(
        from(i in CalendarIntegrationSchema,
          where: i.id == ^calendar_integration_id,
          lock: "FOR KEY SHARE",
          select: i.user_id
        )
      )

    case owner do
      nil ->
        {:error, :integration_gone}

      user_id ->
        Repo.all(
          from(v in VideoIntegrationSchema,
            where: v.user_id == ^user_id,
            order_by: v.id,
            lock: "FOR KEY SHARE",
            select: v.id
          )
        )

        :ok
    end
  end

  @doc """
  Takes the advisory step of the integration cache lock alone, for each of
  `calendar_integration_ids` in id order: what a path that is about to lock
  or delete the integration rows itself takes first. Call it inside a
  transaction.
  """
  @spec lock_cache_class(pos_integer() | [pos_integer()]) :: :ok
  def lock_cache_class(ids) when is_list(ids) do
    ids |> Enum.uniq() |> Enum.sort() |> Enum.each(&lock_cache_class/1)
  end

  def lock_cache_class(calendar_integration_id) when is_integer(calendar_integration_id) do
    Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [
      @integration_cache_lock_class,
      calendar_integration_id
    ])

    :ok
  end

  @doc """
  Takes the advisory step of the integration cache lock for every calendar
  integration `user_id` has, in id order: what deleting the account takes
  before it locks or deletes the user row. Call it inside a transaction.
  """
  @spec lock_cache_class_for_user(pos_integer()) :: :ok
  def lock_cache_class_for_user(user_id) do
    from(i in CalendarIntegrationSchema, where: i.user_id == ^user_id, select: i.id)
    |> Repo.all()
    |> lock_cache_class()
  end

  @doc """
  Runs `fun` in a transaction holding the integration cache lock
  (`lock/1`), answering `{:ok, result}`, `{:error, :integration_gone}`, or
  `{:error, reason}` when `fun` calls `Repo.rollback/1`.
  """
  @spec under_lock(pos_integer(), (-> result)) :: {:ok, result} | {:error, term()}
        when result: term()
  def under_lock(calendar_integration_id, fun) do
    Repo.transaction(fn ->
      case lock(calendar_integration_id) do
        :ok -> fun.()
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc """
  Replaces the integration's cached rows in `scope` with `events_attrs`, in
  one transaction under the integration cache lock: the rows in scope are
  deleted and the new ones inserted, so a reader sees the old set or the new
  one, never neither.

  A full refresh is for a read that returns everything (a published feed).
  An integration with two read paths writing one role each (Exchange) must
  scope it to `{:role, role}`, or each path would delete the other's rows.
  """
  @spec replace_cached_rows(pos_integer(), scope(), [map()]) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def replace_cached_rows(calendar_integration_id, scope, events_attrs)
      when is_list(events_attrs) do
    under_lock(calendar_integration_id, fn ->
      ProviderCalendarEventSchema
      |> where([e], e.calendar_integration_id == ^calendar_integration_id)
      |> where_scope(scope)
      |> Repo.delete_all()

      {:ok, count} = ProviderCalendarEventQueries.upsert_batch(events_attrs)
      count
    end)
  end

  defp where_scope(query, :all), do: query

  defp where_scope(query, {:role, role}) when role in @roles,
    do: where(query, [e], e.role == ^role)

  @doc """
  Deletes cached events that ended before the given cutoff datetime.

  Both timed events (end_at) and all-day events (end_date) are considered.
  Returns the number of deleted rows.
  """
  @spec prune_ended_before(DateTime.t()) :: non_neg_integer()
  def prune_ended_before(cutoff) do
    cutoff_date = DateTime.to_date(cutoff)

    {count, _rows} =
      ProviderCalendarEventSchema
      |> where(
        [e],
        (e.all_day == false and e.end_at < ^cutoff) or
          (e.all_day == true and e.end_date < ^cutoff_date)
      )
      |> Repo.delete_all()

    count
  end

  @doc """
  Deletes all cached events belonging to inactive integrations.

  Returns the number of deleted rows.
  """
  @spec prune_inactive_integrations() :: non_neg_integer()
  def prune_inactive_integrations do
    {count, _rows} =
      ProviderCalendarEventSchema
      |> join(:inner, [e], i in assoc(e, :calendar_integration))
      |> where([_e, i], i.is_active == false)
      |> Repo.delete_all()

    count
  end
end
