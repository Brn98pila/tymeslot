defmodule TymeslotWeb.AdminLiveDeleteUserTest do
  use TymeslotWeb.ConnCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :live
  @moduletag :auth

  import Phoenix.LiveViewTest
  import Tymeslot.AuthTestHelpers
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.Repo
  alias Tymeslot.Workers.AccountDeletionWorker

  setup %{conn: conn} do
    with_config(:tymeslot,
      router: TymeslotWeb.Router,
      enable_admin_ui: true,
      account_deletion_hook: nil
    )

    admin = insert(:user, is_admin: true)
    %{conn: log_in_user(conn, admin), admin: admin}
  end

  test "deletes another user after confirming, and offers no delete for oneself",
       %{conn: conn, admin: admin} do
    target = insert(:user)
    {:ok, view, _html} = live(conn, ~p"/admin/users")

    refute has_element?(view, ~s|button[phx-click="request_delete"][phx-value-id="#{admin.id}"]|)

    view
    |> element(~s|button[phx-click="request_delete"][phx-value-id="#{target.id}"]|)
    |> render_click()

    assert render(view) =~ "their guests are not notified"

    html =
      view
      |> element(~s|#confirm-delete-user-modal button[phx-click="delete_user"]|)
      |> render_click()

    assert html =~ "Deleting #{target.email}"
    assert Repo.get(UserSchema, target.id).deletion_scheduled_at
    assert_enqueued(worker: AccountDeletionWorker, args: %{"user_id" => target.id})
  end

  test "a forged request to delete oneself is refused", %{conn: conn, admin: admin} do
    {:ok, view, _html} = live(conn, ~p"/admin/users")

    html = render_click(view, "delete_user", %{"id" => Integer.to_string(admin.id)})

    assert html =~ "You cannot delete your own account here"
    assert Repo.get(UserSchema, admin.id).deletion_scheduled_at == nil
  end
end
