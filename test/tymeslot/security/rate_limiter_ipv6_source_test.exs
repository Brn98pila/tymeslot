defmodule Tymeslot.Security.RateLimiterIPv6SourceTest do
  @moduledoc """
  Every per-IP bucket counts an IPv6 client by its /64.

  An IPv6 host is usually handed a whole /64 and can pick a fresh address
  from it for every request. A bucket keyed on the full address therefore
  gives that host an unlimited supply of fresh budgets, so these tests rotate
  through addresses in one /64 and expect the bucket to refuse once its
  budget is spent, while a neighbouring /64 keeps its own.

  Each bucket family runs the same test through `parameterize`, so a bucket
  that goes back to keying on the raw address fails under its own name.
  """

  use ExUnit.Case,
    async: false,
    parameterize:
      for(
        {family, limit} <- [
          signup: 5,
          password_reset: 5,
          password_reset_submit: 30,
          verification: 5,
          verification_link: 30,
          email_change_verify: 30,
          oauth_initiation: 10,
          oauth_callback: 20,
          oauth_completion: 6,
          booking_submission: 10,
          meeting_cancel: 10,
          meeting_approval: 20,
          meeting_keep: 10,
          guest_rsvp: 60,
          seat_manage: 60,
          webhook: 100,
          stripe_webhook: 1_000,
          calendar_push: 1_000,
          freebusy_feed: 60,
          meeting_calendar_feed: 60,
          healthcheck: 30
        ],
        do: %{family: family, limit: limit}
      )

  @moduletag :security
  @moduletag :unit

  alias Tymeslot.Security.RateLimiter

  setup do
    RateLimiter.clear_all()
    on_exit(fn -> RateLimiter.clear_all() end)
    :ok
  end

  test "addresses in one IPv6 /64 share a bucket", %{family: family, limit: limit} do
    within_budget = for i <- 1..limit, do: charge(family, address_in("2001:db8:a:b", i))
    assert Enum.reject(within_budget, &(&1 == :allow)) == []

    assert charge(family, address_in("2001:db8:a:b", limit + 1)) == :deny
    assert charge(family, address_in("2001:db8:a:c", 1)) == :allow
  end

  test "an IPv4-mapped address shares the bucket of the IPv4 address it carries",
       %{family: family, limit: limit} do
    within_budget = for _i <- 1..limit, do: charge(family, "198.51.100.7")
    assert Enum.reject(within_budget, &(&1 == :allow)) == []

    assert charge(family, "::ffff:198.51.100.7") == :deny
    assert charge(family, "198.51.100.8") == :allow
  end

  # A distinct host part per call, so every charge comes from a new address.
  defp address_in(prefix, i), do: "#{prefix}:#{Integer.to_string(i, 16)}::1"

  defp charge(family, ip), do: family |> check(ip) |> outcome()

  defp check(:signup, ip), do: RateLimiter.check_signup_ip_rate_limit(ip)
  defp check(:password_reset, ip), do: RateLimiter.check_password_reset_ip_rate_limit(ip)

  defp check(:password_reset_submit, ip),
    do: RateLimiter.check_password_reset_submit_rate_limit(ip)

  defp check(:verification, ip), do: RateLimiter.check_verification_ip_rate_limit(ip)
  defp check(:verification_link, ip), do: RateLimiter.check_verification_link_rate_limit(ip)
  defp check(:email_change_verify, ip), do: RateLimiter.check_email_change_verify_rate_limit(ip)
  defp check(:oauth_initiation, ip), do: RateLimiter.check_oauth_initiation_rate_limit(ip)
  defp check(:oauth_callback, ip), do: RateLimiter.check_oauth_callback_rate_limit(ip)
  defp check(:oauth_completion, ip), do: RateLimiter.check_oauth_completion_rate_limit(ip)
  defp check(:booking_submission, ip), do: RateLimiter.check_booking_submission_limit(ip)
  defp check(:meeting_cancel, ip), do: RateLimiter.check_meeting_cancel_rate_limit(ip)
  defp check(:meeting_approval, ip), do: RateLimiter.check_meeting_approval_rate_limit(ip)
  defp check(:meeting_keep, ip), do: RateLimiter.check_meeting_keep_rate_limit(ip)
  defp check(:guest_rsvp, ip), do: RateLimiter.check_guest_rsvp_rate_limit(ip)
  defp check(:seat_manage, ip), do: RateLimiter.check_seat_manage_rate_limit(ip)
  defp check(:webhook, ip), do: RateLimiter.check_webhook_rate_limit(ip)
  defp check(:stripe_webhook, ip), do: RateLimiter.check_stripe_webhook_rate_limit(ip)
  defp check(:calendar_push, ip), do: RateLimiter.check_calendar_push_rate_limit(ip)
  defp check(:freebusy_feed, ip), do: RateLimiter.check_freebusy_feed_rate_limit(ip)

  defp check(:meeting_calendar_feed, ip),
    do: RateLimiter.check_meeting_calendar_feed_rate_limit(ip)

  defp check(:healthcheck, ip), do: RateLimiter.check_healthcheck_rate_limit(ip)

  defp outcome(:ok), do: :allow
  defp outcome({:allow, _count}), do: :allow
  defp outcome({:deny, _retry_after}), do: :deny
  defp outcome({:error, :rate_limited}), do: :deny
  defp outcome({:error, :rate_limited, _message}), do: :deny
end
