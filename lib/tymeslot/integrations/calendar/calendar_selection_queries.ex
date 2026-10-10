defmodule Tymeslot.Integrations.Calendar.CalendarSelectionQueries do
  @moduledoc """
  Writes to an integration's calendar selection (`calendar_list` and the
  `calendar_paths` derived from it) that start from the row as it stands,
  not from a struct read earlier.

  A selection is rewritten whole, so a write built from a stale struct
  reverts whatever changed in between: a calendar the owner ticked while a
  discovery refresh was on the network, or one an availability read
  deselected. Each function here locks the row (`FOR UPDATE`) inside a
  transaction and applies its change to the fresh row.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Repo
  alias Tymeslot.Utils.UriUtils

  @doc """
  Runs `fun` with the integration `id` locked and freshly read (decrypted),
  inside a transaction, and returns what it returns. `fun` answers
  `{:ok, value}` or `{:error, reason}`; an error rolls the transaction back.
  `{:error, :not_found}` when the row is gone or cannot be read.
  """
  @spec with_locked(pos_integer(), (CalendarIntegrationSchema.t() ->
                                      {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, term()}
  def with_locked(id, fun) when is_integer(id) do
    locked(id, &read_decrypted/1, fun)
  end

  @doc """
  As `with_locked/2`, but hands `fun` the row as stored, whether or not its
  credentials still decrypt: for a write that replaces them, such as a
  reconnect, which is how an unreadable row is repaired.
  """
  @spec with_locked_stored(pos_integer(), (CalendarIntegrationSchema.t() ->
                                             {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, term()}
  def with_locked_stored(id, fun) when is_integer(id) do
    locked(id, &read_stored/1, fun)
  end

  @doc """
  Takes the same row lock as `with_locked_stored/2` inside the caller's
  transaction and answers the row as stored, or `{:error, :not_found}` when it
  is gone. Unlike `with_locked/2` it rolls nothing back, so a caller that
  finds the row gone can go on with the rest of its transaction.

  Must be called from inside a `Repo.transaction/1`.
  """
  @spec lock_stored(pos_integer()) :: {:ok, CalendarIntegrationSchema.t()} | {:error, :not_found}
  def lock_stored(id) when is_integer(id) do
    lock_row(id)
    read_stored(id)
  end

  defp lock_row(id) do
    Repo.one(
      from(ci in CalendarIntegrationSchema,
        where: ci.id == ^id,
        select: ci.id,
        lock: "FOR UPDATE"
      )
    )
  end

  defp locked(id, read, fun) do
    Repo.transaction(fn ->
      lock_row(id)

      with {:ok, fresh} <- read.(id),
           {:ok, value} <- fun.(fresh) do
        value
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp read_decrypted(id) do
    case CalendarIntegrationQueries.get(id) do
      {:error, :requires_reencryption, _stale} -> {:error, :not_found}
      result -> result
    end
  end

  defp read_stored(id) do
    case Repo.get(CalendarIntegrationSchema, id) do
      nil -> {:error, :not_found}
      row -> {:ok, row}
    end
  end

  @doc """
  Marks the given calendars as unselected within an integration's
  `calendar_list`, applied to the row as it stands.

  Used when a previously-selected secondary calendar no longer exists on the
  provider (HTTP 404), so the sync worker stops attempting to fetch it on
  every run. Entries are matched on the provider calendar id. A no-op when
  nothing matches.
  """
  @spec deselect_calendars(CalendarIntegrationSchema.t(), [String.t()]) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, Ecto.Changeset.t() | :not_found}
  def deselect_calendars(%CalendarIntegrationSchema{id: id}, calendar_ids) do
    ids = MapSet.new(calendar_ids)

    with_locked(id, fn fresh ->
      updated_list =
        Enum.map(fresh.calendar_list, fn cal ->
          if MapSet.member?(ids, cal.id), do: %{cal | selected: false}, else: cal
        end)

      fresh
      |> CalendarIntegrationSchema.changeset(%{calendar_list: updated_list})
      |> Repo.update()
    end)
  end

  @doc """
  Removes the given paths from an integration's `calendar_paths`, and
  deselects the `calendar_list` entries for them, in one update applied to
  the row as it stands.

  For a CalDAV collection gone (HTTP 404), like `deselect_calendars/2`:
  pruning paths alone would leave it selected, failing booking pages closed.
  """
  @spec remove_calendar_paths(CalendarIntegrationSchema.t(), [String.t()]) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, Ecto.Changeset.t() | :not_found}
  def remove_calendar_paths(%CalendarIntegrationSchema{id: id}, paths) do
    gone? = fn path -> Enum.any?(paths, &UriUtils.uri_safe_match?(&1, path)) end

    with_locked(id, fn fresh ->
      remaining = Enum.reject(fresh.calendar_paths || [], gone?)

      calendar_list =
        Enum.map(fresh.calendar_list || [], fn cal ->
          if gone?.(cal.path || cal.id), do: %{cal | selected: false}, else: cal
        end)

      fresh
      |> CalendarIntegrationSchema.changeset(%{
        calendar_paths: remaining,
        calendar_list: calendar_list
      })
      |> Repo.update()
    end)
  end

  @doc """
  Drops the removed-calendar entries whose ids are in `shown_ids`: the ones
  the owner was shown when they dismissed the notice. An entry recorded
  since is kept, so the owner still sees it. Whether anything was dropped.
  """
  @spec dismiss_removed_calendars(CalendarIntegrationSchema.t(), [String.t()]) ::
          {:ok, boolean()} | {:error, Ecto.Changeset.t() | :not_found}
  def dismiss_removed_calendars(%CalendarIntegrationSchema{id: id}, shown_ids) do
    shown = MapSet.new(shown_ids)

    with_locked_stored(id, fn fresh ->
      case Enum.reject(fresh.removed_calendars, &MapSet.member?(shown, &1.id)) do
        kept when length(kept) == length(fresh.removed_calendars) ->
          {:ok, false}

        kept ->
          fresh
          |> Changeset.change()
          |> Changeset.put_embed(:removed_calendars, kept)
          |> Repo.update()
          |> then(fn
            {:ok, _updated} -> {:ok, true}
            {:error, changeset} -> {:error, changeset}
          end)
      end
    end)
  end
end
