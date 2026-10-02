defmodule Tymeslot.Auth.AccountDeletion.Request do
  @moduledoc """
  A user asking for their own account to be deleted.

  The account holder proves it is them first: a password account with its
  current password, an account that signs in through a provider by typing
  its email address (`Policy.confirmation_method/1`). The check is held to
  the login rate limit, like every other password check in account settings.

  Then, in one transaction under the user's row lock, the account is marked
  pending (due at now plus the grace period) and its deletion job queued for
  that time. A repeated request keeps the first schedule. A job the queue
  reports as a conflict (one already waiting, or an advisory-lock clash) is
  logged, not failed: the daily sweep re-queues an overdue account whose job
  is missing. After the commit:

    * every session of the account ends, so signing in again is the only way
      back, and while pending that leads to the restore page alone. The
      session making the request (`:current_session_token`) loses its row
      like the rest but keeps its live socket, so the requesting page can
      still deliver its redirect; other open tabs are told over PubSub;
    * the deletion hook hears of it, with the optional exit feedback;
    * the owner is emailed the date, or told the deletion is under way. This
      is the only place that email is queued: the deletion job never sends it.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  require Logger

  alias Tymeslot.Auth.AccountDeletion.{Hook, Policy}
  alias Tymeslot.Auth.{RateLimit, Session, UserQueries, UserSchema, Validation}
  alias Tymeslot.Emails.EmailScheduler
  alias Tymeslot.Infrastructure.PubSub
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Workers.AccountDeletionWorker

  @type error ::
          {:error, %{optional(:current_password | :confirm_email) => String.t()}}
          | {:error, :rate_limited, String.t()}

  @spec request(UserSchema.t(), map(), keyword()) :: {:ok, UserSchema.t()} | error()
  def request(%UserSchema{} = user, params, opts) when is_map(params) do
    RateLimit.with_limit(
      RateLimiter.check_auth_rate_limit(user.email, opts[:ip]),
      [
        event: "account_deletion",
        identifier: user.email,
        ip: opts[:ip],
        user_agent: opts[:user_agent]
      ],
      fn -> do_request(user, params, opts) end
    )
  end

  defp do_request(user, params, opts) do
    now = DateTime.utc_now(:second)

    case schedule(user.id, params, now, Policy.scheduled_at(now)) do
      {:ok, pending} ->
        after_commit(pending, Policy.normalise_feedback(params), opts)
        {:ok, pending}

      {:error, reason} ->
        {:error, field_error(reason)}
    end
  end

  defp schedule(user_id, params, now, scheduled_at) do
    Repo.transaction(fn ->
      with {:ok, user} <- UserQueries.get_user_for_update(user_id),
           :ok <- confirm_identity(user, params),
           {:ok, pending} <- mark_pending(user, now, scheduled_at),
           :ok <- queue_deletion(pending) do
        pending
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  # A second submit (a double click, two tabs) keeps the first schedule.
  defp mark_pending(%UserSchema{deletion_scheduled_at: %DateTime{}} = user, _now, _at),
    do: {:ok, user}

  defp mark_pending(user, now, scheduled_at),
    do: UserQueries.mark_deletion_scheduled(user, now, scheduled_at)

  # A conflict is not proof a job exists (Oban reports one with no id under
  # advisory-lock contention), and not proof it is missing either: the sweep
  # is the safety net, so it is only logged.
  defp queue_deletion(pending) do
    case AccountDeletionWorker.schedule(pending.id, pending.deletion_scheduled_at) do
      {:ok, %Oban.Job{conflict?: true}} ->
        Logger.info("Account deletion job not queued: one is already queued or running",
          user_id: pending.id
        )

        :ok

      {:ok, _job} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp confirm_identity(user, params) do
    case Policy.confirmation_method(user) do
      :password -> Validation.check_current_password(user, params["current_password"])
      :email -> confirm_email(user.email, params["confirm_email"])
    end
  end

  defp confirm_email(email, typed) when is_binary(typed) do
    if normalise_email(typed) == normalise_email(email),
      do: :ok,
      else: {:error, :email_mismatch}
  end

  defp confirm_email(_email, _typed), do: {:error, :email_mismatch}

  defp normalise_email(email), do: email |> String.trim() |> String.downcase()

  defp field_error(reason) when reason in [:invalid_password, :missing_password],
    do: %{current_password: Validation.current_password_message(reason)}

  defp field_error(:not_found),
    do: %{current_password: Validation.current_password_message(:invalid_password)}

  defp field_error(:email_mismatch),
    do: %{confirm_email: dgettext("account", "That is not the email address of this account.")}

  defp field_error(_unexpected) do
    %{
      current_password:
        dgettext("account", "Your account could not be scheduled for deletion. Please try again.")
    }
  end

  defp after_commit(pending, feedback, opts) do
    Session.revoke_all_sessions(pending.id, leave_connected: opts[:current_session_token])
    PubSub.broadcast_account_deletion_requested(pending.id)
    Hook.requested(pending.id, feedback)

    _scheduled =
      EmailScheduler.schedule_account_deletion_notice(%{
        email: pending.email,
        name: pending.name,
        locale: pending.locale,
        scheduled_at: pending.deletion_scheduled_at,
        restorable: not Policy.immediate?()
      })

    :ok
  end
end
