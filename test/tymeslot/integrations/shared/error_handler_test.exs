defmodule Tymeslot.Integrations.Common.ErrorHandlerTest do
  use ExUnit.Case, async: true

  @moduletag :integrations

  import ExUnit.CaptureLog

  alias Tymeslot.Integrations.Common.ErrorHandler
  alias Tymeslot.Test.LogCapture

  describe "handle_with_logging/2" do
    test "returns ok for success" do
      assert {:ok, :success} = ErrorHandler.handle_with_logging(fn -> {:ok, :success} end)
    end

    test "logs and returns error for 2-tuple failure" do
      log =
        capture_log(fn ->
          assert {:error, "fail"} =
                   ErrorHandler.handle_with_logging(fn -> {:error, "fail"} end,
                     operation: "op",
                     provider: "prov"
                   )
        end)

      assert log =~ "Integration error during op (prov): fail"
    end

    test "logs and returns normalized error for 3-tuple failure" do
      log =
        capture_log(fn ->
          assert {:error, "timeout"} =
                   ErrorHandler.handle_with_logging(fn -> {:error, :net, "timeout"} end)
        end)

      assert log =~ "Integration error during unknown operation (unknown provider): timeout"
    end

    test "suppresses logging for specified errors" do
      LogCapture.attach()

      assert {:error, :ignored} =
               ErrorHandler.handle_with_logging(fn -> {:error, :ignored} end,
                 suppress_errors: [:ignored]
               )

      # A suppressed error must produce no log line at all, which `capture_log`
      # cannot express: it captures every process's output, so `log == ""` would
      # trip over concurrently running modules, and matching a substring instead
      # ("ignored") is loose enough to do the same in reverse. Narrowing to the
      # events this process emitted makes the absence assertion exact.
      assert [] == logs_emitted_here()
    end

    test "handles exceptions" do
      log =
        capture_log(fn ->
          assert {:error, "oops"} = ErrorHandler.handle_with_logging(fn -> raise "oops" end)
        end)

      assert log =~ "Integration error during unknown operation (unknown provider): oops"
    end
  end

  # Every log event the code under test emitted, rendered so a failure names the
  # offending line. A :logger handler is global, so events are narrowed to those
  # logged by this process; the handler callback runs in the logging process, so
  # anything logged synchronously has already arrived.
  defp logs_emitted_here do
    LogCapture.drain()
    |> Enum.filter(&(&1.meta.pid == self()))
    |> Enum.map(&LogCapture.dump/1)
  end
end
