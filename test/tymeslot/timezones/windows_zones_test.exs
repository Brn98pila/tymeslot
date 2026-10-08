defmodule Tymeslot.Timezones.WindowsZonesTest do
  use ExUnit.Case, async: true

  @moduletag :calendar
  @moduletag :unit

  alias Tymeslot.Timezones.WindowsZones

  @start ~U[2026-10-05 07:00:00Z]

  describe "from_iana/2" do
    # None of these is its Windows zone's default, and Graph does not list
    # them as IANA names.
    test "names the Windows zone CLDR maps a zone to" do
      for {zone, windows} <- [
            {"Europe/Madrid", "Romance Standard Time"},
            {"Europe/Dublin", "GMT Standard Time"},
            {"Europe/Amsterdam", "W. Europe Standard Time"},
            {"America/Toronto", "Eastern Standard Time"},
            {"Asia/Hong_Kong", "China Standard Time"},
            {"Europe/Berlin", "W. Europe Standard Time"},
            {"Etc/UTC", "UTC"}
          ] do
        assert WindowsZones.from_iana(zone, @start) == windows
      end
    end

    # CLDR spells these the old way (`Asia/Calcutta`, `Asia/Saigon`).
    test "names CLDR's Windows zone for a zone CLDR knows by its old name" do
      assert WindowsZones.from_iana("Asia/Kolkata", @start) == "India Standard Time"
      assert WindowsZones.from_iana("Asia/Ho_Chi_Minh", @start) == "SE Asia Standard Time"
    end

    # America/Montreal is a link CLDR does not list. Cuba keeps its offsets
    # week by week but changes them at another hour, so it is not a match.
    test "names a Windows zone changing its offsets at the same instants for a zone CLDR lacks" do
      assert WindowsZones.from_iana("America/Montreal", @start) == "Eastern Standard Time"
    end

    test "returns a Windows zone name as given" do
      assert WindowsZones.from_iana("Romance Standard Time", @start) == "Romance Standard Time"
    end

    test "falls back to UTC for a zone the time zone database does not know" do
      assert WindowsZones.from_iana("Nowhere/Zone", @start) == "UTC"
    end
  end
end
