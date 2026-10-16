defmodule Tymeslot.AppSettingsEnvPinsTest do
  @moduledoc """
  A setting fixed by an environment variable outranks the admin settings
  page: its stored override is ignored, writes to it are refused, and
  `effective_values/0` names the variable for the admin UI.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :infrastructure

  import Tymeslot.AppSettingsEnvHelpers

  alias Tymeslot.AppSettings
  alias Tymeslot.Auth
  alias TymeslotWeb.Helpers.ClientIP

  setup :restore_app_settings_env

  # What config/runtime.exs produces at boot when the operator sets
  # REGISTRATION_ENABLED=true, followed by the boot-time load.
  defp boot_with_registration_pinned_open do
    Application.put_env(:tymeslot, :registration_enabled, true)
    pin_setting(:registration_enabled, "REGISTRATION_ENABLED")
    AppSettings.load!()
  end

  defp register do
    Auth.register_user(%{"email" => "new@example.com"}, ClientIP.request_opts(%Plug.Conn{}))
  end

  describe "a pinned setting outranks a stored override" do
    test "REGISTRATION_ENABLED=true reopens sign-up that the admin page had closed" do
      {:ok, _settings} = AppSettings.update(%{registration_enabled: false})
      assert {:error, :registration_disabled, _msg} = register()

      boot_with_registration_pinned_open()

      refute match?({:error, :registration_disabled, _msg}, register())
    end

    test "saving an unrelated setting does not overwrite a pinned top-level setting" do
      {:ok, _settings} = AppSettings.update(%{registration_enabled: false})
      boot_with_registration_pinned_open()

      {:ok, _settings} = AppSettings.update(%{booking_analytics_enabled: true})

      assert Application.get_env(:tymeslot, :registration_enabled) == true
    end

    test "saving an unrelated setting does not overwrite a pinned nested setting" do
      {:ok, _settings} = AppSettings.update(%{google_auth_enabled: false})

      Application.put_env(:tymeslot, :social_auth,
        google_enabled: true,
        github_enabled: false,
        oauth_enabled: false
      )

      pin_setting(:google_auth_enabled, "ENABLE_GOOGLE_AUTH")

      {:ok, _settings} = AppSettings.update(%{github_auth_enabled: false})

      assert Keyword.get(Application.get_env(:tymeslot, :social_auth), :google_enabled) == true
    end
  end
end
