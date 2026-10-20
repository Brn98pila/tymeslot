defmodule Tymeslot.Repo.Migrations.LowerUnprovenTymeslotOwnershipOnCachedEvents do
  @moduledoc """
  Clears `created_by_tymeslot` on cached events that an earlier release
  wrongly claimed as Tymeslot's.

  Until the fix released alongside this migration, the CalDAV offline queue
  set the flag on every grid write it queued, including an organiser's edit,
  move or delete of an event somebody else made. A sync never clears the
  flag, so such an event stayed claimed for good, and a queued replay of a
  later edit was granted the `:keep_local` force-write over the owner's own
  changes on the server.

  Outside Google and Outlook the flag lives only in this table, and it is
  provable from it: a cached event is Tymeslot's when its UID is one Tymeslot
  generated (`…@tymeslot.com`, which the grid's creates and the iCalendar
  normaliser's own check both rely on) or when a meeting shares one of its
  identifiers (the rule `Tymeslot.Integrations.Calendar.Sync` raises the flag
  by). A flagged row with neither is lowered; every other row is left alone.

  Two choices keep it on the safe side, since a wrongly lowered booking would
  lose the force-write it is entitled to:

    * the meeting match is not scoped to the row's integration or user, so a
      booking written through an integration that was since reconnected
      still counts;
    * the UID test matches `@tymeslot.com` anywhere in the UID, which also
      keeps the instance rows of a grid-created series.

  Google and Outlook are excluded. Their flag is read from a marker on the
  provider's own copy of the event, which this migration cannot reach, and
  the next sync would raise it again. Those markers are left in place on
  purpose: an event the grid created carries the same marker as a foreign
  event an earlier release stamped while editing it, and nothing on either
  side tells them apart, so removing it would mean rewriting events in the
  organiser's calendar on a guess. What the wrong mark cost there was the
  event's place on the dashboard agenda, and the agenda no longer decides by
  the flag (`Tymeslot.Agenda`); the other apps' properties an edit used to
  overwrite on Google are gone from Google and from the cache alike.

  `down/0` is a no-op: which rows held the wrong flag is not recorded, and
  restoring it would bring the defect back.
  """
  use Ecto.Migration

  # A one-off data repair, which is the whole of the migration. The UPDATE
  # touches only flagged rows, which are a small fraction of the cache.
  # excellent_migrations:safety-assured-for-this-file raw_sql_executed
  # excellent_migrations:safety-assured-for-this-file operation_update

  def up do
    execute("""
    UPDATE provider_calendar_events AS e
    SET created_by_tymeslot = false
    FROM calendar_integrations AS ci
    WHERE e.calendar_integration_id = ci.id
      AND e.created_by_tymeslot
      AND ci.provider NOT IN ('google', 'outlook')
      AND e.uid NOT LIKE '%@tymeslot.com%'
      AND NOT EXISTS (
        SELECT 1
        FROM meetings AS m
        WHERE m.calendar_uid = e.uid
           OR (btrim(coalesce(e.provider_event_id, '')) <> ''
               AND m.provider_event_id = e.provider_event_id)
      )
    """)
  end

  def down, do: :ok
end
