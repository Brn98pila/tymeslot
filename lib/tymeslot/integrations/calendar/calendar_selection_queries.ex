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
    Repo.transaction(fn ->
      Repo.one(
        from(ci in CalendarIntegrationSchema,
          where: ci.id == ^id,
          select: ci.id,
          lock: "FOR UPDATE"
        )
      )

      with {:ok, fresh} <- CalendarIntegrationQueries.get(id),
           {:ok, value} <- fun.(fresh) do
        value
      else
        {:error, :requires_reencryption, _stale} -> Repo.rollback(:not_found)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
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
end
