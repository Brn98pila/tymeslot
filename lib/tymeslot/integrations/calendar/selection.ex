defmodule Tymeslot.Integrations.Calendar.Selection do
  @moduledoc """
  Business logic for calendar discovery/selection merging and preparing params
  for persistence.
  """

  alias Tymeslot.Integrations.Calendar.BookingEligibility
  alias Tymeslot.Integrations.Calendar.CalendarEntry
  alias Tymeslot.Integrations.Calendar.CalendarSelectionQueries
  alias Tymeslot.Integrations.Calendar.ProviderConfig
  alias Tymeslot.Integrations.CalendarManagement
  alias Tymeslot.Utils.UriUtils

  @doc """
  Build the params fragment based on selected calendar paths and discovered items.

  - selected_paths: list of strings
  - discovered: list of calendars with at least path/name/type keys (string or atom keys)

  Returns a map suitable for merging into creation/update params:
    %{calendar_paths: ["a", "b", "c"], calendar_list: [%CalendarEntry{...}]}
  """
  @spec prepare_selected_params([String.t()], list()) ::
          %{required(String.t()) => [String.t()] | [CalendarEntry.t()]}
  def prepare_selected_params(selected_paths, discovered) when is_list(selected_paths) do
    calendar_paths = selected_paths

    selected_calendar_info =
      discovered
      |> Enum.map(&CalendarEntry.normalize/1)
      |> Enum.map(&CalendarEntry.with_defaults/1)
      |> Enum.filter(fn entry ->
        # Match against either path or id — CalDAV discovery emits only `id`
        # (the href), so a path-only filter would silently drop those entries.
        path_in_selected?(entry.path, selected_paths)
      end)
      |> Enum.map(&%{&1 | selected: true})

    %{"calendar_paths" => calendar_paths, "calendar_list" => selected_calendar_info}
  end

  @doc """
  Merge discovered calendars with an existing list of selections.

  A calendar already in `existing_list` keeps the owner's choices, whether it
  is selected and whether it blocks availability. A new one arrives
  deselected, with the blocking default its discovery gave it.
  """
  @spec unify_discovered_with_existing(list(), list()) :: [CalendarEntry.t()]
  def unify_discovered_with_existing(discovered, existing_list) do
    existing_map = build_existing_selection_map(existing_list)

    discovered
    |> Enum.map(&CalendarEntry.normalize/1)
    # CalDAV's XML discovery only emits `id` (the href). Fall back so we
    # always persist a usable path rather than `null`.
    |> Enum.map(&CalendarEntry.with_defaults/1)
    |> Enum.map(fn entry ->
      case lookup_choices(existing_map, [entry.path, entry.id]) do
        nil -> %{entry | selected: false}
        choices -> Map.merge(entry, choices)
      end
    end)
  end

  defp build_existing_selection_map(existing) do
    Enum.reduce(existing, %{}, fn cal, acc ->
      entry = CalendarEntry.normalize(cal)
      choices = Map.take(entry, [:selected, :blocks_availability])

      acc
      |> maybe_put(entry.path, choices)
      |> maybe_put(entry.id, choices)
      |> maybe_put_decoded(entry.path, choices)
      |> maybe_put_decoded(entry.id, choices)
    end)
  end

  defp path_in_selected?(path, selected_paths) do
    Enum.any?(selected_paths, &UriUtils.uri_safe_match?(path, &1))
  end

  # Looks up the stored choices for a calendar identified by any of the given
  # keys (tried in order, each also percent-decoded), or nil for a calendar
  # the existing list does not know.
  defp lookup_choices(existing_map, keys) do
    keys
    |> Enum.flat_map(fn
      nil -> []
      key -> [key, UriUtils.safe_decode(key)]
    end)
    |> Enum.find_value(&Map.get(existing_map, &1))
  end

  defp maybe_put(acc, nil, _val), do: acc
  defp maybe_put(acc, key, val), do: Map.put(acc, key, val)

  defp maybe_put_decoded(acc, nil, _val), do: acc

  defp maybe_put_decoded(acc, key, val) do
    decoded = UriUtils.safe_decode(key)
    if decoded == key, do: acc, else: Map.put(acc, decoded, val)
  end

  @doc """
  Update calendar selection for an integration.
  """
  @spec update_calendar_selection(
          Tymeslot.Integrations.Calendar.CalendarIntegrationSchema.t(),
          %{String.t() => term()}
        ) :: {:ok, Tymeslot.Integrations.Calendar.CalendarIntegrationSchema.t()} | {:error, any()}
  def update_calendar_selection(integration, params) do
    selected_calendar_ids = params["selected_calendars"] || []

    # Applied to the row as it stands, so calendars a discovery refresh added
    # since `integration` was read are kept rather than dropped.
    CalendarSelectionQueries.with_locked(integration.id, fn fresh ->
      calendar_list =
        Enum.map(fresh.calendar_list || [], fn cal ->
          entry = cal |> CalendarEntry.normalize() |> CalendarEntry.with_defaults()
          is_selected = Enum.any?(selected_calendar_ids, &UriUtils.uri_safe_match?(entry.id, &1))
          %{entry | selected: is_selected}
        end)

      persist_calendar_list(fresh, calendar_list)
    end)
  end

  @doc """
  Flips one calendar's selection, leaving every other calendar as the row
  stands. Read and written under the row lock: a selection rebuilt from the
  caller's copy would re-select a calendar a discovery refresh has since
  dropped, or revert a choice made in another tab meanwhile.
  """
  @spec toggle_calendar(
          Tymeslot.Integrations.Calendar.CalendarIntegrationSchema.t(),
          String.t() | integer()
        ) :: {:ok, Tymeslot.Integrations.Calendar.CalendarIntegrationSchema.t()} | {:error, any()}
  def toggle_calendar(integration, calendar_id) do
    calendar_id = to_string(calendar_id)

    CalendarSelectionQueries.with_locked(integration.id, fn fresh ->
      calendar_list =
        Enum.map(fresh.calendar_list || [], fn cal ->
          entry = cal |> CalendarEntry.normalize() |> CalendarEntry.with_defaults()

          if UriUtils.uri_safe_match?(to_string(entry.id), calendar_id),
            do: %{entry | selected: !entry.selected},
            else: entry
        end)

      persist_calendar_list(fresh, calendar_list)
    end)
  end

  @doc """
  Merges freshly `discovered` calendars into the integration's selection and
  persists the result, returning the updated integration and the merged list.

  The merge is made against the row as it stands once discovery is back, not
  against the struct discovery started from: discovery spends seconds on the
  network, and a calendar the owner ticked or unticked meanwhile must keep
  their choice. A merge that would empty a selection that was not empty
  keeps the stored list instead (see `keep_selection_if_emptied/2`).
  """
  @spec persist_discovered(
          Tymeslot.Integrations.Calendar.CalendarIntegrationSchema.t(),
          list()
        ) ::
          {:ok,
           {Tymeslot.Integrations.Calendar.CalendarIntegrationSchema.t(), [CalendarEntry.t()]}}
          | {:error, any()}
  def persist_discovered(%{id: id}, discovered) do
    CalendarSelectionQueries.with_locked(id, fn fresh ->
      merged =
        discovered
        |> unify_discovered_with_existing(fresh.calendar_list)
        |> keep_selection_if_emptied(fresh.calendar_list)

      with {:ok, updated} <- persist_calendar_list(fresh, merged) do
        {:ok, {updated, merged}}
      end
    end)
  end

  # `calendar_paths` is derived from the `selected` flags on `calendar_list`, so
  # a re-discovery that matches nothing — an empty result, or a server that
  # changed the shape of the hrefs it returns — silently deselects everything
  # and leaves the integration syncing no calendars at all. Discovery is
  # triggered by opening a meeting-type form, so this can happen without the
  # owner touching their calendar settings. Keep the stored list whenever the
  # merge would empty a selection that was not empty before; deselecting every
  # calendar deliberately still works, because that goes through
  # `persist_calendar_list/2` directly rather than through discovery.
  defp keep_selection_if_emptied(merged, existing) do
    if derive_selected_paths(merged) == [] and derive_selected_paths(existing || []) != [] do
      existing
    else
      merged
    end
  end

  @doc """
  Writes `attrs`, a whole selection the owner or a fresh connection decided
  on (and, for a reconnect, the new credentials), to the row as it stands,
  under the row lock `persist_discovered/2` takes, so a discovery merge
  cannot interleave with it and undo it. Replaces rather than merges: the
  selection in `attrs` is the one that must win.
  """
  @spec replace_selection(
          Tymeslot.Integrations.Calendar.CalendarIntegrationSchema.t(),
          map()
        ) ::
          {:ok, Tymeslot.Integrations.Calendar.CalendarIntegrationSchema.t()}
          | {:error, Ecto.Changeset.t() | :not_found}
  def replace_selection(%{id: id}, attrs) when is_map(attrs) do
    CalendarSelectionQueries.with_locked_stored(id, fn stored ->
      CalendarManagement.update_calendar_integration(stored, attrs)
    end)
  end

  @doc """
  Persists `calendar_list` together with the `calendar_paths` derived from
  its `selected: true` entries.

  `calendar_paths` is what the CalDAV sync worker iterates over to decide
  which collections to fetch; `calendar_list` carries per-calendar metadata
  (name, type, selected). The two MUST move together — writing one
  without the other is the bug behind issue #50, where toggling a
  calendar off in the dashboard left it being synced because the worker
  never saw the change.

  Always use this rather than passing a bare `%{calendar_list: ...}` to
  `update_calendar_integration/2`.
  """
  @spec persist_calendar_list(
          Tymeslot.Integrations.Calendar.CalendarIntegrationSchema.t(),
          [CalendarEntry.t()]
        ) ::
          {:ok, Tymeslot.Integrations.Calendar.CalendarIntegrationSchema.t()} | {:error, any()}
  def persist_calendar_list(integration, calendar_list) when is_list(calendar_list) do
    CalendarManagement.update_calendar_integration(
      integration,
      calendar_list_attrs(calendar_list)
    )
  end

  @doc """
  Builds the `%{calendar_list: ..., calendar_paths: ...}` attribute pair
  to merge into a multi-field update (e.g. reconnection, which also
  rewrites credentials). For updates that only touch the selection, prefer
  `persist_calendar_list/2`.
  """
  @spec calendar_list_attrs([CalendarEntry.t()]) :: %{
          calendar_list: [CalendarEntry.t()],
          calendar_paths: [String.t()]
        }
  def calendar_list_attrs(calendar_list) when is_list(calendar_list) do
    %{calendar_list: calendar_list, calendar_paths: derive_selected_paths(calendar_list)}
  end

  @doc """
  Returns the paths of the calendars marked `selected: true`.

  Falls back to `id` when `path` is absent (CalDAV discovery emits only
  `id`).
  """
  @spec derive_selected_paths([CalendarEntry.t()]) :: [String.t()]
  def derive_selected_paths(calendar_list) when is_list(calendar_list) do
    for cal <- calendar_list,
        entry = cal |> CalendarEntry.normalize() |> CalendarEntry.with_defaults(),
        entry.selected,
        path = entry.path,
        is_binary(path),
        path != "",
        do: path
  end

  @doc """
  Returns the entries from a `calendar_list` whose `selected` flag is truthy,
  including read-only ones.

  Use this for conflict-checking visibility — a calendar the user cannot
  write to can still surface existing events. Returns `[]` for nil input so
  callers can treat absent and empty selections uniformly. See
  `writable_calendars/1` for the narrower booking/sync-target variant.
  """
  @spec selected_calendars([CalendarEntry.t()] | nil) :: [CalendarEntry.t()]
  def selected_calendars(nil), do: []

  def selected_calendars(calendar_list) when is_list(calendar_list) do
    Enum.filter(calendar_list, & &1.selected)
  end

  @doc """
  Whether `entry`'s busy time removes slots from the booking page: it is
  selected and the owner has not set it to show only. A deselected calendar
  never blocks, whatever its `blocks_availability` says.
  """
  @spec blocking?(CalendarEntry.t()) :: boolean()
  def blocking?(%CalendarEntry{selected: selected, blocks_availability: blocks}),
    do: selected and blocks

  @doc """
  Returns the entries from a `calendar_list` that block availability (see
  `blocking?/1`), read-only ones included. `[]` for nil input.
  """
  @spec blocking_calendars([CalendarEntry.t()] | nil) :: [CalendarEntry.t()]
  def blocking_calendars(nil), do: []

  def blocking_calendars(calendar_list) when is_list(calendar_list),
    do: calendar_list |> Enum.map(&CalendarEntry.normalize/1) |> Enum.filter(&blocking?/1)

  @doc """
  The integration as the availability read must see it: `calendar_list`
  narrowed to its blocking calendars, with `calendar_paths` to match, or
  `nil` when it has a calendar list and none of it blocks.

  Availability reads blocking calendars only, so a calendar set to show only
  is never read for it and can never refuse a slot. Dropping an integration
  with nothing blocking, rather than passing it on with an empty list, is
  load-bearing: Google and Outlook read the account's primary calendar when
  no calendar is selected. An integration with no calendar list predates
  selection and is returned unchanged, everything it has blocking as before.

  An Exchange mailbox is returned unchanged too: its busy time is cached
  mailbox-wide rather than per folder, and blocks whatever folders the owner
  selected.
  """
  @spec availability_view(map()) :: map() | nil
  def availability_view(%{calendar_list: list} = integration) do
    cond do
      list in [nil, []] -> integration
      ProviderConfig.ews?(Map.get(integration, :provider)) -> integration
      true -> narrow_to_blocking(integration, blocking_calendars(list))
    end
  end

  defp narrow_to_blocking(_integration, []), do: nil

  defp narrow_to_blocking(integration, blocking) do
    Map.merge(integration, %{
      calendar_list: blocking,
      calendar_paths: derive_selected_paths(blocking)
    })
  end

  @doc """
  Returns the selected entries from a `calendar_list` that are also
  writable — the calendars available as booking/sync targets. Read-only
  calendars can still be selected for conflict-checking visibility (see
  `selected_calendars/1`) but can never be written to, so they are excluded
  here.
  """
  @spec writable_calendars([CalendarEntry.t()] | nil) :: [CalendarEntry.t()]
  def writable_calendars(calendar_list) do
    calendar_list
    |> selected_calendars()
    |> Enum.reject(& &1.read_only)
  end

  @doc """
  Restricts a list of integrations to those that can take a new event.

  An integration whose calendars are all read-only is not a possible target,
  and offering it is worse than leaving it out: the pickers make it look
  selectable, and the write then fails with `{:error, :read_only}`. A
  subscribed ICS feed is the clearest case — `Ics.Provider` returns a single
  synthetic entry flagged `read_only: true` precisely so it stays out of every
  booking-target picker.

  An integration with **no** calendar list is kept, unless its provider is
  read-only. An empty list means "not discovered yet", not "nothing writable":
  a CalDAV account before its first discovery, or a provider that exposes one
  implicit calendar, both belong in the list and are written to through the
  provider's own default. A read-only provider is dropped whatever its list
  says, so the rule does not depend on every subscription carrying its
  synthetic entry.
  """
  @spec writable_integrations([BookingEligibility.integration()]) ::
          [BookingEligibility.integration()]
  def writable_integrations(integrations) when is_list(integrations) do
    Enum.filter(integrations, &writable_target?/1)
  end

  # Whether `integration` can take a new event. See `writable_integrations/1`.
  @spec writable_target?(BookingEligibility.integration()) :: boolean()
  defp writable_target?(integration) do
    BookingEligibility.bookable?(integration) and has_writable_calendar?(integration)
  end

  defp has_writable_calendar?(%{calendar_list: list}) when is_list(list) and list != [],
    do: writable_calendars(list) != []

  defp has_writable_calendar?(_integration), do: true

  defp find_calendar_by_id(calendar_list, id) when is_list(calendar_list) do
    Enum.find(calendar_list, &(&1.id == id))
  end

  @doc """
  Finds the calendar entry whose `path` is a prefix of the given
  provider-side identifier (e.g. a CalDAV event href). Falls back to `id`
  when `path` is absent — legacy CalDAV integrations persisted `path: nil`.
  """
  @spec find_calendar_by_path([CalendarEntry.t()], String.t() | nil) :: CalendarEntry.t() | nil
  def find_calendar_by_path(calendar_list, path)
      when is_list(calendar_list) and is_binary(path) do
    Enum.find(calendar_list, fn entry ->
      prefix = entry.path || entry.id
      is_binary(prefix) and String.starts_with?(path, prefix)
    end)
  end

  def find_calendar_by_path(_calendar_list, _path), do: nil

  @doc """
  Decides whether a cached calendar event belongs to a calendar the user
  currently has enabled.

  Returns `true` for legacy integrations that have no `calendar_list`
  populated — they predate per-calendar selection, so show everything.
  Otherwise picks the right matching signal for the event's provider:

  - CalDAV events (`provider_event_id` is a CalDAV href starting with `/`)
    match a selected calendar by **path prefix**. The href is rooted at the
    collection the event lives in, so it holds regardless of what
    `provider_calendar_id` says — including for rows written before that
    column was filed per calendar rather than per integration.
  - Other providers (Google, Outlook) tag every cached row with the
    originating calendar in `provider_calendar_id`, so match that against
    the selected entries' `id`.

  Returns `false` only when the integration has a `calendar_list` and the
  event does not match any selected entry — i.e. the user has explicitly
  deselected the calendar this event came from.
  """
  @spec event_visible?(map(), map()) :: boolean()
  def event_visible?(_event, %{calendar_list: nil}), do: true
  def event_visible?(_event, %{calendar_list: []}), do: true

  def event_visible?(event, %{calendar_list: calendar_list}) do
    case selected_calendars(calendar_list) do
      [] -> false
      selected -> not is_nil(calendar_for_event(event, selected))
    end
  end

  @doc """
  Keeps only the cached `events` the user can currently see, judged against the
  integration each came from (see `event_visible?/2`).

  Rows the previous sync wrote for a calendar the user has since deselected stay
  in the cache until pruning runs, so every surface that lists cached events has
  to filter them here to honour the selection immediately. An event whose
  integration is not in `integrations` is kept.
  """
  @spec visible_events([map()], [map()]) :: [map()]
  def visible_events(events, integrations) do
    integration_by_id = Map.new(integrations, &{&1.id, &1})

    Enum.filter(events, fn event ->
      case Map.fetch(integration_by_id, event.calendar_integration_id) do
        :error -> true
        {:ok, integration} -> event_visible?(event, integration)
      end
    end)
  end

  @typedoc """
  A single integration's visibility rule, in the shape a query builder can
  turn into a `where` clause: `:all` (no selection list, show everything),
  `:none` (a selection list with nothing selected, show nothing), or
  `{:selected, entries}` where each entry carries the `provider_calendar_id`
  to match non-CalDAV rows against (`:id`) and the href prefix to match
  CalDAV rows against (`:prefix`).
  """
  @type visibility_rule ::
          :all | :none | {:selected, [%{id: String.t() | nil, prefix: String.t() | nil}]}

  @doc """
  Derives, per integration id, the `t:visibility_rule/0` a SQL query needs to
  filter cached events the same way `visible_events/2` does in memory.

  This is the pure half of that filtering: it reads only `integration.id` and
  `integration.calendar_list`, and returns plain data a query module can turn
  into a `where` clause without depending on this module's types. It mirrors
  `event_visible?/2`'s dispatch exactly: nil/empty `calendar_list` is `:all`,
  a `calendar_list` with nothing selected is `:none`, otherwise the selected
  entries carry both matching signals `calendar_for_event/2` picks between
  (CalDAV path prefix vs `provider_calendar_id`), since which one applies is a
  property of the event, not the integration, and only the query layer sees
  the row.
  """
  @spec visibility_rules([map()]) :: %{integer() => visibility_rule()}
  def visibility_rules(integrations),
    do: rules(integrations, &selected_calendars/1)

  @doc """
  The availability counterpart of `visibility_rules/1`: per integration id,
  the `t:visibility_rule/0` that keeps only cached rows from calendars that
  block availability (see `blocking?/1`). Same shape, so the same query
  builder applies it; a calendar list with nothing blocking is `:none`.
  """
  @spec blocking_rules([map()]) :: %{integer() => visibility_rule()}
  def blocking_rules(integrations),
    do: rules(integrations, &blocking_calendars/1)

  defp rules(integrations, pick) do
    Map.new(integrations, fn integration ->
      {integration.id, integration_rule(integration, pick)}
    end)
  end

  defp integration_rule(%{calendar_list: list}, _pick) when list in [nil, []], do: :all

  defp integration_rule(%{calendar_list: calendar_list}, pick) do
    case pick.(calendar_list) do
      [] -> :none
      entries -> {:selected, Enum.map(entries, &%{id: &1.id, prefix: &1.path || &1.id})}
    end
  end

  @doc """
  Resolves the entry in `calendar_list` that `event` came from, or `nil` when
  no entry matches.

  Picks the same matching signal `event_visible?/2` documents: a CalDAV event
  (whose `provider_event_id` is an href rooted at its collection) matches by
  path prefix, everything else by the `provider_calendar_id` the sync tagged
  the row with. Callers asking a per-calendar question about an event (is it
  visible, is it writable, which calendar does it sit on) must go through here
  rather than re-deriving the match, since the two signals disagree on CalDAV
  and neither an organiser's address nor a default calendar identifies the
  calendar an event was synced from.
  """
  @spec calendar_for_event(map(), [CalendarEntry.t()] | nil) :: CalendarEntry.t() | nil
  def calendar_for_event(_event, nil), do: nil

  def calendar_for_event(event, calendar_list) when is_list(calendar_list) do
    if caldav_event?(event) do
      find_calendar_by_path(calendar_list, event.provider_event_id)
    else
      case Map.get(event, :provider_calendar_id) do
        pcid when is_binary(pcid) -> find_calendar_by_id(calendar_list, pcid)
        _untagged -> nil
      end
    end
  end

  @doc """
  Decides whether an event cached from `integration` sits on a calendar the
  provider will accept writes to.

  Two independent things can make it read-only, and both have to be asked:

    * the provider itself refuses every write (`ProviderConfig.read_only?/1` —
      a subscribed ICS feed, which has no write protocol at all), so no
      calendar under it is writable; and
    * the individual calendar the event came from is read-only, which is
      ordinary on an otherwise writable provider: a Google calendar shared
      with `reader` access, an Outlook calendar reporting `canEdit == false`,
      a CalDAV collection without the write privilege.

  An event whose originating calendar cannot be resolved counts as writable.
  Legacy rows predating per-calendar tagging match no entry, and refusing to
  edit those would break editing on ordinary calendars; the provider-level
  check still covers the wholly read-only providers.
  """
  @spec event_writable?(map(), %{
          :provider => atom() | String.t() | nil,
          :calendar_list => [CalendarEntry.t()] | nil,
          optional(atom()) => term()
        }) :: boolean()
  def event_writable?(event, %{provider: provider, calendar_list: calendar_list}) do
    not ProviderConfig.read_only?(provider) and not read_only_calendar?(event, calendar_list)
  end

  defp read_only_calendar?(event, calendar_list) do
    case calendar_for_event(event, calendar_list) do
      nil -> false
      entry -> entry.read_only
    end
  end

  defp caldav_event?(%{provider_event_id: peid}) when is_binary(peid),
    do: String.starts_with?(peid, "/")

  defp caldav_event?(_event), do: false
end
