defmodule Tymeslot.Security.RateLimiter.Auth do
  @moduledoc false

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Security.RateLimiter.Helpers
  alias Tymeslot.Security.SecurityLogger

  require Logger

  # Per-source tiers. A source can only spend its own budget, so these may
  # run long.
  @signup_limits [
    {"10m", 5, 10 * 60_000},
    {"1h", 8, 60 * 60_000},
    {"1d", 10, 24 * 60 * 60_000},
    {"1w", 12, 7 * 24 * 60 * 60_000},
    {"1mo", 15, 30 * 24 * 60 * 60_000},
    {"1y", 20, 365 * 24 * 60 * 60_000}
  ]

  @verification_limits [
    {"1h", 5, 60 * 60_000},
    {"1d", 10, 24 * 60 * 60_000},
    {"1w", 20, 7 * 24 * 60 * 60_000},
    {"1mo", 25, 30 * 24 * 60 * 60_000},
    {"1y", 50, 365 * 24 * 60 * 60_000}
  ]

  @password_reset_limits [
    {"1h", 5, 60 * 60_000},
    {"1d", 10, 24 * 60 * 60_000},
    {"1w", 20, 7 * 24 * 60 * 60_000},
    {"1mo", 25, 30 * 24 * 60 * 60_000},
    {"1y", 50, 365 * 24 * 60 * 60_000}
  ]

  # Per-recipient tiers: the same budgets, stopping at a day. Anyone who can
  # type an address can spend its budget, so a long tier here would let one
  # source lock the address's owner out for weeks. These buckets are always
  # charged after the source's, so a source over its own limit spends nothing
  # of the recipient's.
  @signup_email_limits [
    {"10m", 5, 10 * 60_000},
    {"1h", 8, 60 * 60_000},
    {"1d", 10, 24 * 60 * 60_000}
  ]

  @verification_user_limits [
    {"1h", 5, 60 * 60_000},
    {"1d", 10, 24 * 60 * 60_000}
  ]

  @password_reset_email_limits [
    {"1h", 5, 60 * 60_000},
    {"1d", 10, 24 * 60 * 60_000}
  ]

  # Per email and client address: the budget a single source gets against one
  # account. Keyed on the pair so that failures from one address can never lock
  # the owner out from another.
  @login_pair_limit 10
  # Per email across every address: only a run spread over many addresses
  # reaches it, so it caps distributed guessing without handing a single
  # attacker a way to lock an account out.
  @login_email_ceiling 50
  @login_window_ms 1_800_000

  # The failed-login throttle, per email and client address: once a pair has
  # ten failures inside the last hour, `check_auth/2` refuses it until the
  # oldest age out. It is a Hammer bucket charged only on failure and cleared
  # on success, so every row it leaves expires with its window and the
  # limiter's periodic clean drops it, whatever the traffic.
  #
  # There is one tier, deliberately. The pre-check in `check_auth/2` is
  # read-only, so once the threshold is reached the login path stops before
  # recording another failure, and a harder tier above it is unreachable by
  # sequential guessing. Making it reachable would mean recording attempts the
  # pre-check already refused, which turns the throttle into a lock anyone who
  # can reach the login form can set off against the account's owner.
  @failed_login_limit 10
  @failed_login_window_ms 3_600_000

  @spec check_auth(String.t(), String.t() | nil) :: :ok | {:error, :rate_limited, String.t()}
  def check_auth(email, ip) do
    # Normalise so whitespace-padded and case-variant emails share one bucket,
    # preventing " User@X.com " / "user@x.com" bypasses of the login limit.
    downcased_email = normalise_email(email)
    pair = login_pair(downcased_email, ip)

    with :ok <- check_failed_logins(pair),
         :ok <-
           Helpers.check_with_logging(
             "login:#{pair}",
             @login_pair_limit,
             @login_window_ms,
             "authentication",
             downcased_email
           ),
         :ok <-
           Helpers.check_with_logging(
             "login:#{downcased_email}",
             @login_email_ceiling,
             @login_window_ms,
             "authentication (account)",
             downcased_email
           ) do
      check_auth_ip_bucket(ip)
    end
  end

  @spec record_attempt(String.t(), String.t() | nil, boolean()) ::
          :ok | {:error, :account_throttled, String.t()}
  def record_attempt(email, ip, true) do
    email |> normalise_email() |> login_pair(ip) |> failed_login_key() |> Helpers.clear_bucket()
  end

  def record_attempt(email, ip, false) do
    downcased_email = normalise_email(email)

    # Fires on every failed attempt, so it is the highest-volume line in the
    # auth path under a credential-stuffing run; the address is masked here
    # rather than left to the global metadata filter.
    Logger.info("Failed attempt recorded",
      identifier_masked: SecurityLogger.mask_email(downcased_email)
    )

    # Charged with a limit one below the threshold, so the failure that
    # brings the count to the threshold is itself the one refused, exactly
    # when the pre-check starts refusing.
    key = downcased_email |> login_pair(ip) |> failed_login_key()

    case Helpers.check_rate(key, @failed_login_window_ms, @failed_login_limit - 1) do
      {:allow, _count} -> :ok
      {:deny, _retry_after_ms} -> {:error, :account_throttled, throttled_message()}
    end
  end

  defp check_failed_logins(pair) do
    if Helpers.bucket_count(failed_login_key(pair), @failed_login_window_ms) >=
         @failed_login_limit,
       do: {:error, :rate_limited, throttled_message()},
       else: :ok
  end

  defp failed_login_key(pair), do: "login_fail:#{pair}"

  defp throttled_message,
    do: dgettext("auth", "Too many failed attempts. Please wait before trying again")

  defp normalise_email(email), do: email |> String.trim() |> String.downcase()

  # The email comes first so a bucket key still reads as the account it guards.
  defp login_pair(downcased_email, ip),
    do: "#{downcased_email}|#{Helpers.source_key(ip)}"

  # The per-source half of the sign-up limit. It runs before the form is
  # validated and refuses out loud: a source can only spend its own budget.
  @spec check_signup_ip(String.t() | :inet.ip_address() | nil) ::
          :ok | {:error, :rate_limited, String.t()}
  def check_signup_ip(ip) do
    Helpers.check_multi_bucket_limits([
      {"signup:ip:#{Helpers.source_key(ip)}", @signup_limits, "signup", signup_action()}
    ])
  end

  # The per-address half, charged only once the source's own budget has
  # allowed the attempt. Anyone can spend it by typing the address, so the
  # sign-up flow answers a refusal here as it answers any sign-up.
  @spec check_signup_recipient(String.t()) :: :ok | {:error, :rate_limited, String.t()}
  def check_signup_recipient(email) do
    # Trimmed as well as downcased, so a padded address cannot buy itself a
    # fresh bucket.
    Helpers.check_multi_bucket_limits([
      {"signup:email:#{normalise_email(email)}", @signup_email_limits, "signup", signup_action()}
    ])
  end

  defp signup_action, do: dgettext("errors", "signup attempts")

  @spec check_verification(String.t(), String.t() | :inet.ip_address() | nil) ::
          :ok | {:error, :rate_limited, String.t()}
  def check_verification(user_id, ip) do
    with :ok <- check_verification_ip(ip), do: check_verification_user(user_id)
  end

  # The two halves of `check_verification/2`, charging the same buckets, for a
  # caller that must charge the address before it knows whether any account
  # is involved (the resend, which must not answer differently for one).
  @spec check_verification_ip(String.t() | :inet.ip_address() | nil) ::
          :ok | {:error, :rate_limited, String.t()}
  def check_verification_ip(ip) do
    Helpers.check_multi_bucket_limits([
      {"email_verification:ip:#{Helpers.source_key(ip)}", @verification_limits,
       "email verification", verification_action()}
    ])
  end

  @spec check_verification_user(term()) :: :ok | {:error, :rate_limited, String.t()}
  def check_verification_user(user_id) do
    Helpers.check_multi_bucket_limits([
      {"email_verification:user:#{user_id}", @verification_user_limits, "email verification",
       verification_action()}
    ])
  end

  # Caps the note sent to an account's owner when someone tries to sign up
  # with their address, so the sign-up form cannot be used to flood a mailbox.
  # Its own bucket, at the per-account verification budget, so that an attempt
  # against an unverified account never spends that account's own resend
  # allowance.
  @spec check_signup_attempt_notice(term()) :: :ok | {:error, :rate_limited, String.t()}
  def check_signup_attempt_notice(user_id) do
    Helpers.check_multi_bucket_limits([
      {"signup_attempt_notice:user:#{user_id}", @verification_user_limits,
       "signup attempt notice", verification_action()}
    ])
  end

  # Caps the link sent to finish a social sign-up with a typed address, per
  # recipient, so the form cannot be used to flood an address with them.
  @spec check_social_signup_confirmation(String.t()) :: :ok | {:error, :rate_limited, String.t()}
  def check_social_signup_confirmation(email) do
    Helpers.check_multi_bucket_limits([
      {"social_signup_confirmation:email:#{normalise_email(email)}", @verification_user_limits,
       "social signup confirmation", verification_action()}
    ])
  end

  defp verification_action, do: dgettext("errors", "verification emails")

  # Two separate checks, so that the reset flow can refuse on the source's
  # budget and stay silent on the recipient's.
  @spec check_password_reset_ip(String.t() | :inet.ip_address() | nil) ::
          :ok | {:error, :rate_limited, String.t()}
  def check_password_reset_ip(ip) do
    Helpers.check_multi_bucket_limits([
      {"password_reset:ip:#{Helpers.source_key(ip)}", @password_reset_limits, "password reset",
       password_reset_action()}
    ])
  end

  @spec check_password_reset_recipient(String.t()) :: :ok | {:error, :rate_limited, String.t()}
  def check_password_reset_recipient(email) do
    Helpers.check_multi_bucket_limits([
      {"password_reset:email:#{String.downcase(email)}", @password_reset_email_limits,
       "password reset", password_reset_action()}
    ])
  end

  defp password_reset_action, do: dgettext("errors", "password reset requests")

  @spec check_email_change_verify(String.t()) :: :ok | {:error, :rate_limited, String.t()}
  def check_email_change_verify(client_ip) do
    Helpers.check_with_logging(
      "email_change_verify:#{Helpers.source_key(client_ip)}",
      30,
      60_000,
      "email change verification",
      client_ip
    )
  end

  # Setting a new password against a reset token, per IP: the token is the
  # only secret on that form, and each attempt pays for a bcrypt hash.
  @spec check_password_reset_submit(String.t() | nil) ::
          :ok | {:error, :rate_limited, String.t()}
  def check_password_reset_submit(client_ip) do
    Helpers.check_with_logging(
      "password_reset_submit:#{Helpers.source_key(client_ip)}",
      30,
      60_000,
      "password reset submission",
      client_ip
    )
  end

  # Completing an emailed verification link, per IP, as for email-change links.
  @spec check_verification_link(String.t() | nil) :: :ok | {:error, :rate_limited, String.t()}
  def check_verification_link(client_ip) do
    Helpers.check_with_logging(
      "verification_link:#{Helpers.source_key(client_ip)}",
      30,
      60_000,
      "email verification link",
      client_ip
    )
  end

  defp check_auth_ip_bucket(ip) when is_binary(ip) and ip != "" do
    Helpers.check_with_logging(
      "login_ip:#{Helpers.source_key(ip)}",
      50,
      1_800_000,
      "authentication (ip)",
      ip
    )
  end

  defp check_auth_ip_bucket(_invalid_ip), do: :ok
end
