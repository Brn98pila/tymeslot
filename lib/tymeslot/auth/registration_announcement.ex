defmodule Tymeslot.Auth.RegistrationAnnouncement do
  @moduledoc """
  Announces a completed registration: durably to the configured
  `:user_registered_hook`, through a retried Oban job, and to in-process
  subscribers over PubSub.

  The hook gets a job rather than the broadcast because whatever it records
  (terms acceptance, say) must not depend on a subscriber process being
  alive at the moment of sign-up. With no hook configured, only the
  broadcast happens.
  """

  require Logger

  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Infrastructure.PubSub
  alias Tymeslot.Workers.UserRegisteredHookWorker

  @doc """
  Runs both announcements for `user`. Never fails the registration: an
  enqueue failure is logged, since the account itself is already complete.
  """
  @spec announce(struct(), map()) :: :ok
  def announce(user, metadata) do
    if Application.get_env(:tymeslot, :user_registered_hook) do
      enqueue_hook(user.id, metadata)
    end

    PubSub.broadcast_user_registered(user, metadata)
  end

  defp enqueue_hook(user_id, metadata) do
    case user_id |> UserRegisteredHookWorker.new_job(metadata) |> Oban.insert() do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.error("Could not enqueue the registration hook",
          user_id: user_id,
          reason: LogFormat.reason(reason)
        )
    end
  end
end
