defmodule Tymeslot.Profiles.CreateProfileTest do
  use Tymeslot.DataCase, async: true

  @moduletag :profiles

  alias Tymeslot.Profiles

  describe "create_profile/1" do
    # The loser of two concurrent first loads used to raise
    # Ecto.ConstraintError; it now gets the profile the winner created.
    test "returns the existing profile when one was created first" do
      user = insert(:user)
      {:ok, first} = Profiles.create_profile(user.id)

      assert {:ok, second} = Profiles.create_profile(user.id)
      assert second.id == first.id
    end

    test "refuses a user deleted meanwhile without raising" do
      user = insert(:user)
      Repo.delete!(user)

      assert {:error, :user_not_found} = Profiles.create_profile(user.id)
    end
  end

  describe "get_or_create_profile/1" do
    test "refuses a user deleted meanwhile without raising" do
      user = insert(:user)
      Repo.delete!(user)

      assert {:error, :user_not_found} = Profiles.get_or_create_profile(user.id)
    end
  end
end
