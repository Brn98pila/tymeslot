defmodule Tymeslot.Utils.DateTimeUtils.Display do
  @moduledoc "The period of day a time slot falls in."

  alias Tymeslot.Utils.DateTimeUtils

  @doc """
  The period of day a slot string falls in: "Early Morning", "Morning",
  "Afternoon", "Evening" or "Late Night", or "Unknown" when it does not parse.
  """
  @spec get_time_period(String.t()) :: String.t()
  def get_time_period(slot_string) do
    case DateTimeUtils.parse_time_string(slot_string) do
      {:ok, time} ->
        determine_period_from_hour(time.hour)

      {:error, _parse_error} ->
        "Unknown"
    end
  end

  defp determine_period_from_hour(hour) when hour >= 0 and hour < 5, do: "Early Morning"
  defp determine_period_from_hour(hour) when hour >= 5 and hour < 12, do: "Morning"
  defp determine_period_from_hour(hour) when hour >= 12 and hour < 17, do: "Afternoon"
  defp determine_period_from_hour(hour) when hour >= 17 and hour < 21, do: "Evening"
  defp determine_period_from_hour(_hour), do: "Late Night"
end
