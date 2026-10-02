defmodule Tymeslot.Auth.AccountDeletion.HookTest do
  use ExUnit.Case, async: false

  @moduletag :auth
  @moduletag :unit

  import Tymeslot.ConfigTestHelpers

  alias Tymeslot.Auth.AccountDeletion.Hook

  defmodule RecordingHook do
    @behaviour Tymeslot.Auth.Behaviours.AccountDeletionHook

    @impl Tymeslot.Auth.Behaviours.AccountDeletionHook
    def on_deletion_requested(user_id, feedback) do
      send(self(), {:requested, user_id, feedback})
      :ok
    end

    @impl Tymeslot.Auth.Behaviours.AccountDeletionHook
    def on_deletion_restored(user_id) do
      send(self(), {:restored, user_id})
      {:error, :stripe_down}
    end

    @impl Tymeslot.Auth.Behaviours.AccountDeletionHook
    def on_account_deletion(user_id) do
      send(self(), {:deleted, user_id})
      {:error, :stripe_down}
    end
  end

  test "with no hook configured every call is a no-op" do
    with_config(:tymeslot, :account_deletion_hook, nil)

    assert Hook.requested(1, nil) == :ok
    assert Hook.restored(1) == :ok
    assert Hook.deleted(1) == :ok
  end

  test "passes the request and its feedback to the hook" do
    with_config(:tymeslot, :account_deletion_hook, RecordingHook)

    assert Hook.requested(7, %{reason: "other", comment: nil}) == :ok
    assert_received {:requested, 7, %{reason: "other", comment: nil}}
  end

  test "a failing restore callback is logged, never returned" do
    with_config(:tymeslot, :account_deletion_hook, RecordingHook)

    assert Hook.restored(7) == :ok
    assert_received {:restored, 7}
  end

  test "a failing delete callback is returned so the deletion stops" do
    with_config(:tymeslot, :account_deletion_hook, RecordingHook)

    assert Hook.deleted(7) == {:error, :stripe_down}
    assert_received {:deleted, 7}
  end
end
