defmodule Tymeslot.ReleaseDeleteAccountTest do
  use Tymeslot.DataCase, async: false

  @moduletag :auth

  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.Release
  alias Tymeslot.Repo

  setup do
    with_config(:tymeslot, :account_deletion_hook, nil)
    :ok
  end

  test "deletes the account with that address and waits for it" do
    user = insert(:user, email: "leaver@example.com")

    assert Release.delete_account("leaver@example.com") == {:ok, :deleted}
    refute Repo.get(UserSchema, user.id)
  end

  test "refuses the only admin without force" do
    insert(:user, is_admin: true, email: "root@example.com")

    assert Release.delete_account("root@example.com") == {:error, :last_admin}
  end

  test "reports an unknown address" do
    assert Release.delete_account("nobody@example.com") == {:error, :not_found}
  end
end
