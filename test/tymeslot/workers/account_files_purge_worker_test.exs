defmodule Tymeslot.Workers.AccountFilesPurgeWorkerTest do
  @moduledoc """
  A deleted account whose uploaded files cannot be removed at once: the
  removal is retried in the background, and the operator is alerted once
  every retry is spent, so personal files never outlive the account silently.

  A directory made read-only stands in for the failure. Not async: the
  admin alert capture is global configuration.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :auth
  @moduletag :profiles

  import Tymeslot.AdminAlertsCaptureHelpers
  import Tymeslot.Factory

  alias Tymeslot.Auth
  alias Tymeslot.Media.Uploads
  alias Tymeslot.Workers.AccountFilesPurgeWorker

  setup :capture_admin_alerts

  setup do
    profile = insert(:profile, avatar: "avatar.png")
    dir = Path.join([Uploads.root(), "avatars", Integer.to_string(profile.id)])
    File.mkdir_p!(dir)
    avatar = Path.join(dir, "avatar.png")
    File.write!(avatar, "bytes")

    # The file cannot be unlinked while its directory is read-only.
    File.chmod!(dir, 0o500)
    on_exit(fn -> File.chmod(dir, 0o700) && File.rm_rf(dir) end)

    %{profile: profile, dir: dir, avatar: avatar}
  end

  test "deleting the account queues a retry instead of leaving the files behind",
       %{profile: profile, dir: dir, avatar: avatar} do
    assert {:ok, _deleted} = Auth.delete_account(profile.user)

    assert File.exists?(avatar)
    assert_enqueued(worker: AccountFilesPurgeWorker, args: %{"profile_id" => profile.id})

    File.chmod!(dir, 0o700)

    assert :ok = perform_job(AccountFilesPurgeWorker, %{"profile_id" => profile.id})
    refute File.exists?(dir)
    refute_received {:send_alert, _type, _payload}
  end

  test "a failed retry before the last attempt is retried, without an alert",
       %{profile: profile, avatar: avatar} do
    assert {:error, [%{files: :avatars}]} =
             perform_job(AccountFilesPurgeWorker, %{"profile_id" => profile.id}, attempt: 1)

    assert File.exists?(avatar)
    refute_received {:send_alert, _type, _payload}
  end

  test "the last failed attempt alerts the operator with the paths to remove",
       %{profile: profile, dir: dir} do
    assert {:cancel, _reason} =
             perform_job(AccountFilesPurgeWorker, %{"profile_id" => profile.id}, attempt: 5)

    assert_received {:send_alert, :account_files_delete_failed, payload}
    assert payload.profile_id == profile.id
    assert payload.paths =~ dir
  end
end
