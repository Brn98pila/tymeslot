defmodule TymeslotWeb.AccountRestoreHTML do
  @moduledoc """
  The restore page for an account pending deletion. Deliberately bare: the
  date, a button to restore and a button to sign out, and no dashboard
  chrome, so nothing of the account's data is shown while it is frozen.
  Once the date has passed, `expired/1` says the account can no longer be
  restored and offers only the sign-out button.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  attr :deletion_date, :string, required: true
  attr :error, :string, default: nil

  @spec show(map()) :: Phoenix.LiveView.Rendered.t()
  def show(assigns) do
    ~H"""
    <.frame title={dgettext("auth", "Your account is being deleted")}>
      <p class="mt-2 text-token-base text-tymeslot-600">
        {dgettext(
          "auth",
          "Your account is in the process of being deleted (scheduled for %{date}). If you want to keep it, restore it here.",
          date: @deletion_date
        )}
      </p>

      <p :if={@error} role="alert" class="mt-4 text-token-sm text-red-600">{@error}</p>

      <form method="post" action={~p"/auth/restore"} class="mt-6">
        <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
        <.action_button type="submit" class="w-full">
          {dgettext("auth", "Restore my account")}
        </.action_button>
      </form>

      <.sign_out />
    </.frame>
    """
  end

  @spec expired(map()) :: Phoenix.LiveView.Rendered.t()
  def expired(assigns) do
    ~H"""
    <.frame title={dgettext("auth", "Your account is being deleted")}>
      <p class="mt-2 text-token-base text-tymeslot-600">
        {dgettext("auth", "Your account is being deleted and can no longer be restored.")}
      </p>

      <.sign_out />
    </.frame>
    """
  end

  attr :title, :string, required: true
  slot :inner_block, required: true

  defp frame(assigns) do
    ~H"""
    <main class="flex min-h-screen items-center justify-center bg-linear-to-br from-turquoise-50 via-white to-cyan-50 p-4">
      <div class="w-full max-w-md rounded-token-2xl bg-white p-8 text-center shadow-glass-lg">
        <div class="mx-auto flex h-16 w-16 items-center justify-center rounded-token-full bg-amber-100 text-amber-600">
          <.icon name="hero-clock" class="h-9 w-9" />
        </div>

        <h1 class="mt-6 text-token-2xl font-bold text-tymeslot-800">{@title}</h1>
        {render_slot(@inner_block)}
      </div>
    </main>
    """
  end

  defp sign_out(assigns) do
    ~H"""
    <form method="post" action={~p"/auth/logout"} class="mt-3">
      <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
      <input type="hidden" name="_method" value="delete" />
      <.action_button type="submit" variant={:secondary} class="w-full">
        {dgettext("auth", "Sign out")}
      </.action_button>
    </form>
    """
  end
end
