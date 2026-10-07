defmodule Tymeslot.AppSettingsEnvHelpers do
  @moduledoc """
  Shared `setup` and env helpers for the `AppSettings` test modules.

  `AppSettings.load!/0` runs on application boot, and these tests toggle
  Application env directly, so the environment must be snapshotted and
  restored around each test. Extracted here so `AppSettingsTest` and
  `AppSettingsLockoutTest` share one copy rather than duplicating the block.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Tymeslot.AppSettings

  @doc """
  ExUnit `setup` callback that snapshots and restores the AppSettings-related
  Application env (every leaf key plus the parent `:social_auth` keyword list).
  Use as `setup :restore_app_settings_env`.
  """
  @spec restore_app_settings_env(map()) :: :ok
  def restore_app_settings_env(_context) do
    originals =
      Map.new(AppSettings.keys(), fn key -> {key, Application.get_env(:tymeslot, key)} end)

    # `AppSettings.keys()` only enumerates leaf setting keys; the parent
    # `:social_auth` keyword list (mutated indirectly via update/1 and by
    # `clamp_sso_disabled/0`) needs its own snapshot/restore so a single
    # test can't leak SSO state into the next.
    original_social_auth = Application.get_env(:tymeslot, :social_auth)

    on_exit(fn ->
      # Clear any DB override that a test may have applied for every editable key.
      clear_attrs = Map.new(AppSettings.keys(), fn key -> {key, nil} end)
      {:ok, _settings} = AppSettings.update(clear_attrs)

      # Restore the Application env snapshot captured before the test ran.
      Enum.each(originals, fn
        {key, nil} -> Application.delete_env(:tymeslot, key)
        {key, value} -> Application.put_env(:tymeslot, key, value)
      end)

      case original_social_auth do
        nil -> Application.delete_env(:tymeslot, :social_auth)
        value -> Application.put_env(:tymeslot, :social_auth, value)
      end
    end)

    :ok
  end

  @doc """
  Forces every SSO provider off for the current test. The `restore_app_settings_env`
  setup snapshots `:social_auth` and restores it on exit, so callers don't need
  their own cleanup.
  """
  @spec clamp_sso_disabled() :: :ok
  def clamp_sso_disabled do
    Application.put_env(:tymeslot, :social_auth,
      google_enabled: false,
      github_enabled: false,
      oauth_enabled: false
    )
  end

  @doc """
  Enables the generic OIDC provider and gives it client credentials, so it
  counts as a usable sign-in path. `restore_app_settings_env/1` restores
  `:social_auth`; `:oauth_provider` is not an AppSettings key, so this
  restores it itself.
  """
  @spec enable_credentialed_oauth() :: :ok
  def enable_credentialed_oauth do
    original = Application.get_env(:tymeslot, :oauth_provider)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:tymeslot, :oauth_provider)
        value -> Application.put_env(:tymeslot, :oauth_provider, value)
      end
    end)

    Application.put_env(:tymeslot, :oauth_provider,
      client_id: "oidc-client-id",
      client_secret: "oidc-client-secret"
    )

    Application.put_env(:tymeslot, :social_auth,
      google_enabled: false,
      github_enabled: false,
      oauth_enabled: true
    )
  end
end
