defmodule Tymeslot.Security.RateLimiterRefusalLoggingTest do
  @moduledoc """
  Which limits write a "Rate limit exceeded" warning when they refuse.

  Most do. The silent ones are flood caps on machine-to-machine endpoints and
  limits whose refusal was never logged (form keystrokes, public poll voting,
  settings edits); a warning per refused request there would bury the
  refusals worth reading.
  """

  use ExUnit.Case, async: false

  @moduletag :security

  import ExUnit.CaptureLog

  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Security.RateLimiter.Limits

  @silent ~w(
    analytics_ip analytics_visitor availability_add_break availability_quick_break
    availability_update_hours calendar_push calendar_webhook freebusy healthcheck
    meeting_ics payment_initiation poll_register poll_vote stripe_webhook theme_upload
    username_change username_check webhook webhook_form webhook_form_validate
  )a

  setup do
    RateLimiter.clear_all()
    on_exit(&RateLimiter.clear_all/0)
    :ok
  end

  test "exactly these limits refuse without logging" do
    silent = for {name, entry} <- Limits.all(), entry[:log] == false, do: name
    assert Enum.sort(silent) == Enum.sort(@silent)
  end

  for name <- @silent do
    test "#{name} refuses without a warning" do
      assert refusal_log(unquote(name)) == ""
    end
  end

  test "a logged limit warns when it refuses" do
    assert refusal_log(:meeting_cancel) =~ "Rate limit exceeded"
  end

  # Spends the limit's whole budget quietly, then captures what the refusal
  # itself logs.
  defp refusal_log(name) do
    entry = Limits.fetch!(name)
    key = key_for(entry[:scope])

    for _i <- 1..smallest_limit(entry), do: :ok = RateLimiter.check(name, key)

    capture_log([level: :warning], fn ->
      assert {:error, :rate_limited, _message} = RateLimiter.check(name, key)
    end)
  end

  defp smallest_limit(entry) do
    case entry[:tiers] do
      nil -> entry[:limit]
      tiers -> tiers |> Enum.map(&elem(&1, 1)) |> Enum.min()
    end
  end

  defp key_for(:source), do: "203.0.113.9"
  defp key_for(scope) when scope in [:user, :id], do: 42
  defp key_for(:email), do: "ada@example.com"
  defp key_for(:key), do: "user:42"
end
