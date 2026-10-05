defmodule Tymeslot.Security.RateLimiterMultiWindowTest do
  use Tymeslot.DataCase, async: false
  @moduletag :security

  alias Tymeslot.Security.RateLimiter

  describe "signup multi-window limits (email + IP)" do
    test "the IP bucket blocks after 5 attempts in 10 minutes, across emails" do
      ip = "203.0.113.10"

      for _i <- 1..5, do: assert(:ok = RateLimiter.check_signup_ip_rate_limit(ip))

      assert {:error, :rate_limited, _msg} = RateLimiter.check_signup_ip_rate_limit(ip)
      assert :ok = RateLimiter.check_signup_ip_rate_limit("203.0.113.11")
    end

    test "the address bucket blocks after 5 attempts in 10 minutes, per address" do
      email = "user1@example.com"

      for _i <- 1..5, do: assert(:ok = RateLimiter.check_signup_recipient_rate_limit(email))

      assert {:error, :rate_limited, _msg} =
               RateLimiter.check_signup_recipient_rate_limit(email)

      assert :ok = RateLimiter.check_signup_recipient_rate_limit("user2@example.com")
    end
  end

  describe "verification resend multi-window limits (user + IP)" do
    test "blocks after 5 attempts in 1 hour" do
      user_id = "user-123"
      ip = "198.51.100.7"

      Enum.each(1..5, fn _i ->
        assert :ok = RateLimiter.check_verification_rate_limit(user_id, ip)
      end)

      assert {:error, :rate_limited, _msg} =
               RateLimiter.check_verification_rate_limit(user_id, ip)
    end
  end

  describe "password reset multi-window limits (email + IP)" do
    test "blocks after 5 attempts in 1 hour" do
      email = "reset@example.com"
      ip = "192.0.2.44"

      Enum.each(1..5, fn _i ->
        assert :ok = RateLimiter.check_password_reset_rate_limit(email, ip)
      end)

      assert {:error, :rate_limited, _msg} =
               RateLimiter.check_password_reset_rate_limit(email, ip)
    end

    test "normalizes nil IPs for password reset buckets" do
      email = "reset-nil@example.com"

      Enum.each(1..5, fn _i ->
        assert :ok = RateLimiter.check_password_reset_rate_limit(email, nil)
      end)

      assert {:error, :rate_limited, _msg} =
               RateLimiter.check_password_reset_rate_limit(email, nil)
    end
  end

  describe "failed-login throttle under concurrent failures" do
    test "a concurrent burst of failures engages the throttle" do
      email = "concurrent-lockout@example.com"

      tasks =
        for _i <- 1..20 do
          Task.async(fn -> RateLimiter.record_auth_attempt(email, nil, false) end)
        end

      results = Task.await_many(tasks, 10_000)

      assert Enum.any?(results, &match?({:error, :account_throttled, _}, &1))

      assert {:error, :rate_limited, message} = RateLimiter.check_auth_rate_limit(email, nil)
      assert message =~ "Too many failed attempts"
    end
  end

  describe "booking recipient multi-window limits (per attendee email)" do
    test "blocks after 5 bookings to one mailbox within the hour" do
      email = "victim@example.com"

      Enum.each(1..5, fn _i ->
        assert :ok = RateLimiter.check_booking_recipient_limit(email)
      end)

      assert {:error, :rate_limited, _msg} = RateLimiter.check_booking_recipient_limit(email)
    end

    test "the bucket is per-recipient — a different mailbox is unaffected" do
      bombed = "bombed@example.com"
      other = "other-recipient@example.com"

      Enum.each(1..6, fn _i -> RateLimiter.check_booking_recipient_limit(bombed) end)

      assert {:error, :rate_limited, _msg} = RateLimiter.check_booking_recipient_limit(bombed)
      assert :ok = RateLimiter.check_booking_recipient_limit(other)
    end

    test "case and whitespace variants of an address share one bucket" do
      Enum.each(1..5, fn _i ->
        assert :ok = RateLimiter.check_booking_recipient_limit("Mixed.Case@Example.com")
      end)

      # A padded, lower-cased variant must not get a fresh allowance.
      assert {:error, :rate_limited, _msg} =
               RateLimiter.check_booking_recipient_limit("  mixed.case@example.com  ")
    end
  end

  # One client must not be able to lock another out of an address it does not
  # own: the per-recipient buckets are charged only once the source's own
  # budget has allowed the request, and keep no count for longer than a day.
  @day_ms 24 * 60 * 60_000

  describe "per-recipient budgets" do
    test "a verification source over its own limit spends nothing of the account's budget" do
      user_id = "verification-victim"
      attacker_ip = "203.0.113.62"

      for _i <- 1..5, do: assert(:ok = RateLimiter.check_verification_ip_rate_limit(attacker_ip))

      for _i <- 1..10 do
        assert {:error, :rate_limited, _msg} =
                 RateLimiter.check_verification_rate_limit(user_id, attacker_ip)
      end

      assert :ok = RateLimiter.check_verification_rate_limit(user_id, "203.0.113.63")
    end

    test "no count is kept against an address or account for longer than a day" do
      email = "recipient-window@example.com"
      user_id = "recipient-window-user"

      assert :ok = RateLimiter.check_signup_recipient_rate_limit(email)
      assert :ok = RateLimiter.check_password_reset_rate_limit(email, "203.0.113.65")
      assert :ok = RateLimiter.check_verification_rate_limit(user_id, "203.0.113.66")

      for bucket <- [
            "signup:email:#{email}",
            "password_reset:email:#{email}",
            "email_verification:user:#{user_id}"
          ] do
        windows = windows_ms(bucket)
        assert windows != [], "no tier recorded for #{bucket}"
        assert Enum.max(windows) <= @day_ms, "#{bucket} keeps a tier longer than a day"
      end
    end
  end

  # The span of every live entry Hammer's sliding window holds under the tiers
  # of `bucket`: each entry is `{{key, inserted_at_us}, expires_at_us}`.
  defp windows_ms(bucket) do
    for {{key, inserted_at}, expires_at} <- :ets.tab2list(Tymeslot.Security.RateLimit),
        is_binary(key),
        String.starts_with?(key, bucket <> ":") do
      div(expires_at - inserted_at, 1000)
    end
  end
end
