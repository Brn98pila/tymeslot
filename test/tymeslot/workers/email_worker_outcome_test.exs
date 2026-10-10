defmodule Tymeslot.Workers.EmailWorkerOutcomeTest do
  @moduledoc """
  What `EmailWorker` hands Oban for a handler's result it has no special
  rule for: the reason as it came, so the job's recorded error says what
  went wrong.
  """

  # async: false: the handler's result is fixed by patching the dispatcher
  # with :meck, which replaces the module for every process.
  use Tymeslot.DataCase, async: false

  @moduletag :emails

  alias Tymeslot.Notifications.EmailHandlers
  alias Tymeslot.Workers.EmailWorker

  test "an error reason with no rule of its own is kept, not replaced by \"Unknown error\"" do
    assert {:error, {:http_error, 500, "provider down"}} =
             perform_returning({:error, {:http_error, 500, "provider down"}})
  end

  test "a result outside the handler contract is kept inside the error" do
    assert {:error, {:unexpected_result, {:ok, :sent}}} = perform_returning({:ok, :sent})
  end

  defp perform_returning(result) do
    :meck.new(EmailHandlers, [:passthrough])

    :meck.expect(EmailHandlers, :execute_email_action, fn _action, _args, _job_id ->
      result
    end)

    try do
      EmailWorker.perform(%Oban.Job{
        id: System.unique_integer([:positive]),
        attempt: 1,
        args: %{"action" => "send_no_password_to_reset", "user_id" => 1}
      })
    after
      :meck.unload(EmailHandlers)
    end
  end
end
