defmodule Tymeslot.Integrations.Calendar.Blocking do
  @moduledoc """
  Writes to whether a calendar blocks availability (its
  `CalendarEntry.blocks_availability`), and the rule that a booking calendar
  always does.

  A calendar bookings are written to must block, or the host's own events in
  it would be ignored when slots are offered. A booking calendar is the one
  `Defaults.booking_target/1` names for an integration (its stored default,
  else the provider's primary) and any calendar a meeting type names as its
  `target_calendar_id`. So `set/3` refuses to make one show only, and choosing
  a calendar as a booking target (`promote_booking_target/3`,
  `set_default_booking_calendar/2`) makes it block in the same write. Nothing
  demotes it again: a calendar stays blocking when a meeting type stops
  naming it, or is deleted.

  ## Lock order

  Each write here holds its integration's row `FOR UPDATE`, the lock every
  selection write takes (`CalendarSelectionQueries.with_locked/2`, or
  `lock_stored/1` inside a meeting type's transaction, which must go on when
  the integration is gone). A meeting-type write that names a booking calendar
  runs `promote_booking_target/3` first, in its own transaction, so it locks:

    1. the user's row, `FOR KEY SHARE` (`CalendarIntegrationQueries.lock_owner/1`);
    2. the calendar integration's row, `FOR UPDATE`;
    3. the meeting type's row, by writing it.

  Deleting an integration locks its row before it clears the meeting types
  that name it, and deleting an account locks the user's row before its
  cascade reaches either, so neither can hold a meeting type this waits for.
  None of these take the integration cache lock or touch cached events;
  `IntegrationCacheQueries` documents that order, which a cache write meets
  only at the integration row and waits there.

  Every write that changes which calendars block drops the owner's cached
  availability once it commits, never before: a read in between would cache
  the old answer again. A write nested in a caller's transaction (a default
  booking calendar stored while `PrimaryElection` hands the primary on)
  leaves that to the caller, which commits.
  """

  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Integrations.Calendar.CalendarEntry
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.CalendarSelectionQueries
  alias Tymeslot.Integrations.Calendar.Defaults
  alias Tymeslot.Integrations.Calendar.ProviderConfig
  alias Tymeslot.Integrations.Calendar.Selection
  alias Tymeslot.Integrations.CalendarManagement
  alias Tymeslot.MeetingTypes.BookingCalendar
  alias Tymeslot.Utils.UriUtils

  @type integration :: CalendarIntegrationSchema.t()

  @doc """
  Sets whether the calendar `calendar_id` of `integration` blocks
  availability.

  `{:error, :booking_calendar}` when asked to make a booking calendar show
  only; `{:error, :not_found}` when the integration lists no such calendar.
  """
  @spec set(integration(), String.t() | integer(), boolean()) ::
          {:ok, integration()} | {:error, :booking_calendar | :not_found | term()}
  def set(%{id: id}, calendar_id, blocks?) when is_boolean(blocks?) do
    calendar_id = to_string(calendar_id)

    id
    |> CalendarSelectionQueries.with_locked(fn fresh ->
      cond do
        is_nil(find(fresh.calendar_list, calendar_id)) ->
          {:error, :not_found}

        not blocks? and booking_calendar?(fresh, calendar_id) ->
          {:error, :booking_calendar}

        true ->
          Selection.persist_calendar_list(fresh, put(fresh.calendar_list, calendar_id, blocks?))
      end
    end)
    |> invalidate_on_success()
  end

  @typedoc """
  What the owner lets a calendar do: nothing (`:off`, not selected), appear
  in Tymeslot without taking slots (`:show`), or appear and take slots
  (`:block`).
  """
  @type state :: :off | :show | :block

  @doc """
  Sets whether the calendar `calendar_id` of `integration` is used, and
  whether it blocks availability, in one write.

  `{:error, :booking_calendar}` for anything but `:block` on a booking
  calendar; `{:error, :free_busy_only}` for `:show` on a calendar shared as
  busy times only, which has no events to show; `{:error, :not_found}` when
  the integration lists no such calendar.
  """
  @spec set_state(integration(), String.t() | integer(), state()) ::
          {:ok, integration()}
          | {:error, :booking_calendar | :free_busy_only | :not_found | term()}
  def set_state(%{id: id}, calendar_id, state) when state in [:off, :show, :block] do
    calendar_id = to_string(calendar_id)

    id
    |> CalendarSelectionQueries.with_locked(fn fresh ->
      case find(fresh.calendar_list, calendar_id) do
        nil ->
          {:error, :not_found}

        entry ->
          with :ok <- allowed(fresh, entry, state) do
            Selection.persist_calendar_list(
              fresh,
              put_state(fresh.calendar_list, entry.id, state)
            )
          end
      end
    end)
    |> invalidate_on_success()
  end

  defp allowed(integration, entry, state) when state in [:off, :show] do
    cond do
      booking_calendar?(integration, entry.id) -> {:error, :booking_calendar}
      state == :show and entry.free_busy_only -> {:error, :free_busy_only}
      true -> :ok
    end
  end

  defp allowed(_integration, _entry, :block), do: :ok

  defp put_state(calendar_list, calendar_id, state) do
    Enum.map(calendar_list, fn cal ->
      entry = CalendarEntry.normalize(cal)

      cond do
        entry.id != calendar_id -> entry
        state == :off -> %{entry | selected: false}
        true -> %{entry | selected: true, blocks_availability: state == :block}
      end
    end)
  end

  @doc """
  Sets whether the calendar `calendar_id` of `integration` is shown (used),
  leaving whether it blocks as it is: for an Exchange mailbox's main
  calendar, whose busy time blocks whether or not it is shown.
  `{:error, :not_found}` when the integration lists no such calendar.
  """
  @spec set_shown(integration(), String.t() | integer(), boolean()) ::
          {:ok, integration()} | {:error, :not_found | term()}
  def set_shown(%{id: id}, calendar_id, shown?) when is_boolean(shown?) do
    calendar_id = to_string(calendar_id)

    id
    |> CalendarSelectionQueries.with_locked(fn fresh ->
      case find(fresh.calendar_list, calendar_id) do
        nil ->
          {:error, :not_found}

        entry ->
          Selection.persist_calendar_list(
            fresh,
            Enum.map(fresh.calendar_list, fn cal ->
              if cal.id == entry.id, do: %{cal | selected: shown?}, else: cal
            end)
          )
      end
    end)
    |> invalidate_on_success()
  end

  @doc """
  Whether `entry` of `integration` blocks the booking page, for a surface
  that says so. An Exchange mailbox blocks through its main calendar alone,
  shown or not; any other calendar when it is used and set to block.
  """
  @spec blocks?(%{provider: String.t() | atom()}, CalendarEntry.t()) :: boolean()
  def blocks?(%{provider: provider}, %CalendarEntry{} = entry) do
    if ProviderConfig.ews?(provider),
      do: entry.primary and entry.blocks_availability,
      else: Selection.blocking?(entry)
  end

  @doc """
  The `t:state/0` an entry is in.
  """
  @spec state(CalendarEntry.t()) :: state()
  def state(%CalendarEntry{selected: false}), do: :off
  def state(%CalendarEntry{blocks_availability: false}), do: :show
  def state(%CalendarEntry{}), do: :block

  @doc """
  Whether `calendar_id` is a booking calendar of `integration`: the calendar
  bookings on it go to, or one a meeting type of its owner names.

  On an Exchange mailbox only the main calendar is held to the rule: busy
  time is read for the mailbox through it, and another folder cannot block
  whatever it is set to.
  """
  @spec booking_calendar?(integration(), String.t()) :: boolean()
  def booking_calendar?(integration, calendar_id) do
    held_to_rule?(integration, calendar_id) and
      integration
      |> booking_calendar_ids()
      |> Enum.any?(&UriUtils.uri_safe_match?(&1, calendar_id))
  end

  defp held_to_rule?(integration, calendar_id) do
    not ProviderConfig.ews?(integration.provider) or
      match?(%CalendarEntry{primary: true}, find(integration.calendar_list, calendar_id))
  end

  defp booking_calendar_ids(integration) do
    default_booking_ids(integration) ++
      BookingCalendar.ids(integration.user_id, integration.id)
  end

  defp default_booking_ids(integration) do
    case Defaults.booking_target(integration) do
      {_writable, %CalendarEntry{id: id}} -> [id]
      :none -> []
    end
  end

  @doc """
  Per integration id, the ids of its booking calendars (see
  `booking_calendar?/2`), for a page listing the user's `integrations`
  together. One query, whatever the number of integrations.
  """
  @spec booking_calendar_ids_by_integration(pos_integer(), [integration()]) ::
          %{pos_integer() => [String.t()]}
  def booking_calendar_ids_by_integration(user_id, integrations) do
    targets = BookingCalendar.ids_by_integration(user_id)

    Map.new(integrations, fn integration ->
      {integration.id,
       Enum.uniq(default_booking_ids(integration) ++ Map.get(targets, integration.id, []))}
    end)
  end

  @doc """
  Makes `calendar_id` of the user's integration `integration_id` block, as a
  meeting type is about to name it as its booking calendar. Call it inside
  the transaction that writes the meeting type, before that write (see the
  lock order in the moduledoc).

  `{:ok, :promoted}` when it changed the calendar, `{:ok, :unchanged}` when
  it already blocked, or when the integration or the calendar is gone (the
  meeting type's own validation answers for those), and `{:error, :not_found}`
  when the user is gone, their account deleted while this waited.
  """
  @spec promote_booking_target(pos_integer(), pos_integer(), String.t()) ::
          {:ok, :promoted | :unchanged} | {:error, term()}
  def promote_booking_target(user_id, integration_id, calendar_id) do
    with true <- CalendarIntegrationQueries.lock_owner(user_id),
         {:ok, %{user_id: ^user_id} = stored} <-
           CalendarSelectionQueries.lock_stored(integration_id) do
      promote(stored, calendar_id)
    else
      false -> {:error, :not_found}
      _gone_or_another_users -> {:ok, :unchanged}
    end
  end

  defp promote(fresh, calendar_id) do
    case find(fresh.calendar_list, calendar_id) do
      %CalendarEntry{blocks_availability: false} ->
        with {:ok, _updated} <-
               Selection.persist_calendar_list(fresh, put(fresh.calendar_list, calendar_id, true)),
             do: {:ok, :promoted}

      _blocking_or_unlisted ->
        {:ok, :unchanged}
    end
  end

  @doc """
  Stores `calendar_id` as the integration's default booking calendar, making
  it block in the same write. Read and written under the integration's row
  lock, so a selection changed meanwhile is kept.
  """
  @spec set_default_booking_calendar(integration(), String.t()) ::
          {:ok, integration()} | {:error, Ecto.Changeset.t() | :not_found | term()}
  def set_default_booking_calendar(%{id: id}, calendar_id) do
    id
    |> CalendarSelectionQueries.with_locked(fn fresh ->
      attrs =
        case find(fresh.calendar_list, calendar_id) do
          %CalendarEntry{blocks_availability: false} ->
            Selection.calendar_list_attrs(put(fresh.calendar_list, calendar_id, true))

          _blocking_or_unlisted ->
            %{}
        end

      CalendarManagement.update_calendar_integration(
        fresh,
        Map.put(attrs, :default_booking_calendar_id, calendar_id)
      )
    end)
    |> invalidate_on_success()
  end

  @doc """
  `calendar_list` with the entry `calendar_id` made to block, for a write
  that stores a list and its default booking calendar together.
  """
  @spec with_booking_calendar_blocking([CalendarEntry.t()], String.t() | nil) ::
          [CalendarEntry.t()]
  def with_booking_calendar_blocking(calendar_list, nil), do: calendar_list

  def with_booking_calendar_blocking(calendar_list, calendar_id),
    do: put(calendar_list, calendar_id, true)

  defp find(calendar_list, calendar_id) do
    Enum.find(calendar_list || [], fn cal ->
      UriUtils.uri_safe_match?(CalendarEntry.normalize(cal).id, calendar_id)
    end)
  end

  defp put(calendar_list, calendar_id, blocks?) do
    Enum.map(calendar_list || [], fn cal ->
      entry = CalendarEntry.normalize(cal)

      if UriUtils.uri_safe_match?(entry.id, calendar_id),
        do: %{entry | blocks_availability: blocks?},
        else: entry
    end)
  end

  defp invalidate_on_success({:ok, %{user_id: user_id}} = ok) do
    unless CalendarIntegrationQueries.in_transaction?(), do: AvailabilityCache.invalidate_for_user(user_id)
    ok
  end

  defp invalidate_on_success(error), do: error
end
