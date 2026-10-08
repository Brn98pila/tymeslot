defmodule Tymeslot.Integrations.Calendar.TokenUtils do
  @moduledoc """
  Relative-time formatting for token expiry shown on the dashboard.
  """

  @doc """
  Converts a DateTime to a human-readable relative time string.
  """
  @spec relative_time(DateTime.t()) :: String.t()
  def relative_time(datetime) do
    now = DateTime.utc_now()
    diff_seconds = DateTime.diff(datetime, now)
    abs_diff = abs(diff_seconds)

    format_relative_time(abs_diff, diff_seconds)
  end

  defp format_relative_time(abs_diff, _diff_seconds) when abs_diff < 60 do
    "just now"
  end

  defp format_relative_time(abs_diff, diff_seconds) when abs_diff < 3600 do
    format_time_unit(abs_diff, diff_seconds, 60, "minute")
  end

  defp format_relative_time(abs_diff, diff_seconds) when abs_diff < 86_400 do
    format_time_unit(abs_diff, diff_seconds, 3600, "hour")
  end

  defp format_relative_time(abs_diff, diff_seconds) when abs_diff < 2_592_000 do
    format_time_unit(abs_diff, diff_seconds, 86_400, "day")
  end

  defp format_relative_time(abs_diff, diff_seconds) do
    format_time_unit(abs_diff, diff_seconds, 2_592_000, "month")
  end

  defp format_time_unit(abs_diff, diff_seconds, divisor, unit_name) do
    count = div(abs_diff, divisor)
    unit = if count == 1, do: unit_name, else: "#{unit_name}s"

    if diff_seconds > 0 do
      "in #{count} #{unit}"
    else
      "#{count} #{unit} ago"
    end
  end
end
