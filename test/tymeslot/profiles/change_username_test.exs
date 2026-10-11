defmodule Tymeslot.Profiles.ChangeUsernameTest do
  use Tymeslot.DataCase, async: true

  @moduletag :profiles

  alias Tymeslot.Profiles
  alias Tymeslot.Profiles.ProfileQueries
  alias Tymeslot.Security.RateLimiter

  describe "publishing the booking page on username set" do
    test "publishes when the user already has an active meeting type" do
      user = insert(:user)
      profile = insert(:profile, user: user, username: nil)
      insert(:meeting_type, user: user, is_active: true)

      assert {:ok, _updated} = Profiles.change_username(profile, "newhost")

      {:ok, reloaded} = ProfileQueries.get_by_user_id(user.id)
      assert %DateTime{} = reloaded.booking_page_published_at
    end

    test "does not publish when the user has no active meeting type" do
      user = insert(:user)
      profile = insert(:profile, user: user, username: nil)

      assert {:ok, _updated} = Profiles.change_username(profile, "newhost")

      {:ok, reloaded} = ProfileQueries.get_by_user_id(user.id)
      assert reloaded.booking_page_published_at == nil
    end

    test "a system-assigned username publishes when the user already has an active meeting type" do
      user = insert(:user)
      profile = insert(:profile, user: user, username: nil)
      insert(:meeting_type, user: user, is_active: true)

      assert {:ok, _updated} =
               Profiles.change_username(profile, "autohost", skip_rate_limit: true)

      {:ok, reloaded} = ProfileQueries.get_by_user_id(user.id)
      assert %DateTime{} = reloaded.booking_page_published_at
    end
  end

  describe "change_username/3" do
    test "skip_rate_limit writes through an exhausted change allowance" do
      profile = insert(:profile, username: nil)
      key = "user:" <> Integer.to_string(profile.user_id)
      for _n <- 1..6, do: RateLimiter.check(:username_change, key)

      assert {:error, "Too many username change attempts. Please try again later."} =
               Profiles.change_username(profile, "limited-host")

      assert {:ok, %{username: "system-host"}} =
               Profiles.change_username(profile, "system-host", skip_rate_limit: true)
    end

    test "writes nothing for the profile's current username" do
      profile = insert(:profile, username: "same-host")

      assert {:ok, ^profile} = Profiles.change_username(profile, "same-host")
    end
  end
end
