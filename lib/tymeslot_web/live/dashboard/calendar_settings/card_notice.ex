defmodule TymeslotWeb.Dashboard.CalendarSettings.CardNotice do
  @moduledoc """
  The one notice a calendar integration's card shows: whatever needs the
  owner's action first (the connection, then changes its server refused),
  then the calendars its server stopped listing, which need none.
  """
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias TymeslotWeb.Components.Dashboard.Integrations.Shared.ConnectionLabels

  @doc """
  The card's notice for `integration`, given its health state and its stuck
  changes (`nil` for none), or `nil` when there is nothing to say.
  """
  @spec notice(CalendarIntegrationSchema.t() | map(), map() | nil, map() | nil) ::
          String.t() | nil
  def notice(integration, health_state, stuck) do
    ConnectionLabels.calendar_notice(integration, health_state) || stuck_notice(stuck) ||
      removed_notice(Map.get(integration, :removed_calendars, []))
  end

  # A change the server kept refusing is no longer sent, so until the owner
  # retries it the calendar differs from what the grid shows. The error is
  # stored as an English msgid (a CalDAV error, or Tymeslot's own reason for
  # skipping the change) and translated as it is shown.
  defp stuck_notice(nil), do: nil

  defp stuck_notice(%{count: count, last_error: nil}) do
    dngettext(
      "dashboard_calendar_settings",
      "1 change made here was not saved to this calendar.",
      "%{count} changes made here were not saved to this calendar.",
      count
    )
  end

  defp stuck_notice(%{count: count, last_error: error}) do
    dngettext(
      "dashboard_calendar_settings",
      "1 change made here was not saved to this calendar. Last error: %{error}",
      "%{count} changes made here were not saved to this calendar. Last error: %{error}",
      count,
      error: ConnectionLabels.translate_reason(error)
    )
  end

  # A calendar the server stopped listing is no longer used, which the owner
  # sees until they dismiss it.
  defp removed_notice([]), do: nil

  defp removed_notice([%{name: calendar}]) do
    dgettext(
      "dashboard_calendar_settings",
      "“%{calendar}” is no longer on your calendar server, so Tymeslot has stopped using it.",
      calendar: calendar
    )
  end

  defp removed_notice(removed) do
    dngettext(
      "dashboard_calendar_settings",
      "%{count} calendar is no longer on your calendar server, so Tymeslot has stopped using it: %{calendars}",
      "%{count} calendars are no longer on your calendar server, so Tymeslot has stopped using them: %{calendars}",
      length(removed),
      calendars: Enum.map_join(removed, ", ", &"“#{&1.name}”")
    )
  end
end
