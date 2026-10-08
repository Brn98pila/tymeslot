defmodule Tymeslot.Timezones.WindowsZonesTest do
  use ExUnit.Case, async: true

  @moduletag :calendar
  @moduletag :unit

  alias Tymeslot.Timezones.WindowsZones

  describe "from_iana/1" do
    test "names the Windows zone a default IANA zone belongs to" do
      assert WindowsZones.from_iana("Europe/Berlin") == "W. Europe Standard Time"
      assert WindowsZones.from_iana("Asia/Kolkata") == "India Standard Time"
      assert WindowsZones.from_iana("Etc/UTC") == "UTC"
    end

    # None of these is a Windows zone's default, and Graph does not list them.
    test "names a Windows zone with the same offsets for any other zone" do
      for {zone, windows} <- [
            {"Europe/Madrid", "Central Europe Standard Time"},
            {"Europe/Dublin", "GMT Standard Time"},
            {"Asia/Hong_Kong", "China Standard Time"}
          ] do
        assert WindowsZones.from_iana(zone) == windows
      end
    end

    # Cuba keeps Toronto's offsets week by week but changes them at another
    # hour, so it is not a match.
    test "requires the offsets to change at the same instants" do
      assert WindowsZones.from_iana("America/Toronto") == "Eastern Standard Time"
    end

    test "returns a Windows zone name as given" do
      assert WindowsZones.from_iana("Romance Standard Time") == "Romance Standard Time"
    end

    test "falls back to UTC for a zone the time zone database does not know" do
      assert WindowsZones.from_iana("Nowhere/Zone") == "UTC"
    end
  end
end
