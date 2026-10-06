defmodule Tymeslot.Auth.UserRegisteredHookTest do
  @moduledoc """
  The durable registration hook. Whatever a hook records from a sign-up (the
  terms acceptance, for one) runs from a retried Oban job enqueued when the
  account is created, rather than from a PubSub message that a restarting
  subscriber can miss.
  """

  # async: false: the hook is global Application env.
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :auth
  @moduletag :workers

  alias Tymeslot.Auth
  alias Tymeslot.Workers.UserRegisteredHookWorker
  alias TymeslotWeb.Helpers.ClientIP

  defmodule RecordingHook do
    @spec on_user_registered(pos_integer(), map()) :: :ok
    def on_user_registered(user_id, metadata) do
      send(
        Application.fetch_env!(:tymeslot, :registration_hook_test_pid),
        {:hook, user_id, metadata}
      )

      :ok
    end
  end

  defmodule FailingHook do
    @spec on_user_registered(pos_integer(), map()) :: {:error, term()}
    def on_user_registered(_user_id, _metadata), do: {:error, :database_unavailable}
  end

  setup do
    original = Application.get_env(:tymeslot, :user_registered_hook)
    Application.put_env(:tymeslot, :registration_hook_test_pid, self())

    on_exit(fn ->
      Application.delete_env(:tymeslot, :registration_hook_test_pid)

      if original,
        do: Application.put_env(:tymeslot, :user_registered_hook, original),
        else: Application.delete_env(:tymeslot, :user_registered_hook)
    end)

    :ok
  end

  defp register do
    params = %{
      "email" => "hooked#{System.unique_integer([:positive])}@example.com",
      "password" => "ValidPassword123!",
      "password_confirmation" => "ValidPassword123!",
      "name" => "Hooked User",
      "terms_accepted" => "true"
    }

    opts = Keyword.put(ClientIP.request_opts(%Plug.Conn{}), :user_agent, "HookTest/1.0")
    {:ok, user, _session} = Auth.register_user(params, opts)
    user
  end

  test "a sign-up enqueues the hook, which receives the sign-up's metadata" do
    Application.put_env(:tymeslot, :user_registered_hook, RecordingHook)

    user = register()

    assert [job] = all_enqueued(worker: UserRegisteredHookWorker)
    assert job.args["user_id"] == user.id

    assert :ok = perform_job(UserRegisteredHookWorker, job.args)

    user_id = user.id
    assert_received {:hook, ^user_id, metadata}
    assert metadata["terms_accepted"] == true
    assert metadata["user_agent"] == "HookTest/1.0"
    assert metadata["source"] == "signup"
  end

  test "a hook failure is returned so Oban retries the job" do
    Application.put_env(:tymeslot, :user_registered_hook, FailingHook)

    assert {:error, :database_unavailable} =
             perform_job(UserRegisteredHookWorker, %{"user_id" => 1, "metadata" => %{}})
  end

  test "without a hook, a sign-up enqueues nothing" do
    Application.delete_env(:tymeslot, :user_registered_hook)

    register()

    assert all_enqueued(worker: UserRegisteredHookWorker) == []
  end
end
