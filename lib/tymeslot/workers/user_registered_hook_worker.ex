defmodule Tymeslot.Workers.UserRegisteredHookWorker do
  @moduledoc """
  Runs the configured `:user_registered_hook` for one completed
  registration (see `Tymeslot.Auth.Behaviours.UserRegisteredHook`). An
  `{:error, reason}` from the hook is retried with Oban's backoff.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 10,
    unique: [period: 3600, keys: [:user_id]]

  @doc """
  Builds the job for `user_id`. Only JSON-safe metadata values are kept, so
  a stray tuple or struct cannot make the insert fail.
  """
  @spec new_job(pos_integer(), map()) :: Oban.Job.changeset()
  def new_job(user_id, metadata) do
    new(%{"user_id" => user_id, "metadata" => json_safe(metadata)})
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id} = args}) do
    case Application.get_env(:tymeslot, :user_registered_hook) do
      nil -> :ok
      hook -> hook.on_user_registered(user_id, Map.get(args, "metadata", %{}))
    end
  end

  defp json_safe(metadata) when is_map(metadata) do
    for {key, value} <- metadata,
        is_atom(key) or is_binary(key),
        is_binary(value) or is_boolean(value) or is_number(value) or is_nil(value),
        into: %{},
        do: {to_string(key), value}
  end

  defp json_safe(_metadata), do: %{}
end
