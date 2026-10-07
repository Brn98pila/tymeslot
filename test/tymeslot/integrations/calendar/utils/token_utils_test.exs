defmodule Tymeslot.Integrations.Calendar.TokenUtilsTest do
  use Tymeslot.DataCase, async: true

  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.TokenUtils

  describe "relative_time/1" do
    test "formats various time diffs" do
      now = DateTime.utc_now()
      assert TokenUtils.relative_time(DateTime.add(now, 30, :second)) == "just now"
      assert TokenUtils.relative_time(DateTime.add(now, 150, :second)) == "in 2 minutes"
      assert TokenUtils.relative_time(DateTime.add(now, -150, :second)) == "2 minutes ago"
      assert TokenUtils.relative_time(DateTime.add(now, 7500, :second)) == "in 2 hours"
      assert TokenUtils.relative_time(DateTime.add(now, 180_000, :second)) == "in 2 days"
      assert TokenUtils.relative_time(DateTime.add(now, 6_000_000, :second)) == "in 2 months"
    end
  end
end
