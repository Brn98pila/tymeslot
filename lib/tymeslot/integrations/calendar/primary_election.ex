defmodule Tymeslot.Integrations.Calendar.PrimaryElection do
  @moduledoc """
  Chooses the calendar that becomes a user's primary (booking) calendar when
  the current one stops being usable: it was deleted, switched off by its
  owner, or paused for being unhealthy.

  One rule for every path: the newest integration that is active, not waiting
  to be reconnected, and bookable (not read-only). A paused or read-only
  calendar is never promoted, since every booking written to it would fail.
  When none qualifies the primary is cleared.

  Callers run this inside their own transaction, after taking
  `CalendarIntegrationWebhookQueries.lock_user_profile_and_integrations/1`,
  so a concurrent delete, toggle or pause cannot elect from a list the other
  is changing.
  """

  alias Tymeslot.Integrations.Calendar.BookingEligibility
  alias Tymeslot.Integrations.CalendarManagement
  alias Tymeslot.Integrations.CalendarPrimary
  alias Tymeslot.Profiles.ProfileQueries

  @type outcome :: {:promoted, pos_integer()} | :cleared | :unchanged

  @doc """
  Makes the next eligible integration of `user_id`, other than those in
  `exclude_ids`, the primary, or clears the primary when none is eligible.

  A candidate refused by `CalendarPrimary.set_primary_calendar_integration/2`
  (it changed or vanished since it was listed) is excluded and the next one
  tried; each pass excludes one more id, so this terminates.
  """
  @spec elect_next(pos_integer(), [pos_integer()]) :: outcome()
  def elect_next(user_id, exclude_ids) do
    candidates =
      user_id
      |> CalendarManagement.list_active_calendar_integrations()
      |> Enum.reject(&(&1.id in exclude_ids or &1.needs_reauth))
      |> BookingEligibility.filter_bookable()
      |> Enum.sort(&newer?/2)

    case candidates do
      [next | _rest] ->
        case CalendarPrimary.set_primary_calendar_integration(user_id, next.id) do
          {:ok, _integration} -> {:promoted, next.id}
          {:error, _reason} -> elect_next(user_id, [next.id | exclude_ids])
        end

      [] ->
        case ProfileQueries.clear_primary_calendar_integration(user_id) do
          {:ok, _profile} -> :cleared
          _error -> :unchanged
        end
    end
  end

  # Newest first; the id breaks a tie between rows inserted in one second.
  defp newer?(a, b) do
    case DateTime.compare(a.inserted_at, b.inserted_at) do
      :gt -> true
      :lt -> false
      :eq -> a.id >= b.id
    end
  end
end
