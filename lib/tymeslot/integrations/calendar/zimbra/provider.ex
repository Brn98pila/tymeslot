defmodule Tymeslot.Integrations.Calendar.Zimbra.Provider do
  @moduledoc """
  Zimbra provider that leverages the shared CalDAV base module.

  Zimbra uses CalDAV for calendar access with the standard path pattern:
  /dav/{username}/ for calendar discovery.

  This provider is a thin configuration layer over the base CalDAV
  implementation, providing Zimbra-specific defaults and messaging.
  """

  @behaviour Tymeslot.Integrations.Calendar.Provider

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Integrations.Calendar.CalDAV.EventProcessor
  alias Tymeslot.Integrations.Calendar.CalendarEntry
  alias Tymeslot.Integrations.Calendar.Providers.CaldavCommon
  alias Tymeslot.Integrations.Calendar.Shared.{ErrorHandler, ProviderCommon}
  alias Tymeslot.Integrations.Shared.ProviderConfigHelper

  @impl Tymeslot.Integrations.Calendar.Provider
  def provider_type, do: :zimbra

  @impl Tymeslot.Integrations.Calendar.Provider
  def display_name, do: "Zimbra"

  @impl Tymeslot.Integrations.Calendar.Provider
  def connection_test_bucket, do: :caldav

  @doc "Returns the component module that renders the CalDAV-family configuration form"
  @spec setup_component() :: module()
  def setup_component,
    do: TymeslotWeb.Components.Dashboard.Integrations.Calendar.CaldavFamilyConfig

  @impl Tymeslot.Integrations.Calendar.Provider
  def config_schema do
    %{
      base_url: %{
        type: :string,
        required: true,
        description:
          "Zimbra server URL (e.g., https://mail.example.com) or full CalDAV URL (e.g., https://mail.example.com/dav/user@example.com)"
      },
      username: %{
        type: :string,
        required: true,
        description: "Zimbra username (usually your email address)"
      },
      password: %{
        type: :string,
        required: true,
        description: "Zimbra password"
      },
      calendar_paths: %{
        type: :list,
        required: false,
        description: "List of calendar paths to sync (auto-discovered if not provided)"
      },
      connection_timeout: %{
        type: :integer,
        required: false,
        default: 10_000,
        description: "Connection timeout in milliseconds (default: 10 seconds)"
      },
      request_timeout: %{
        type: :integer,
        required: false,
        default: 30_000,
        description: "Request timeout in milliseconds (default: 30 seconds)"
      },
      discovery_timeout: %{
        type: :integer,
        required: false,
        default: 15_000,
        description: "Calendar discovery timeout in milliseconds (default: 15 seconds)"
      }
    }
  end

  # Structural validation only, in line with every other provider's
  # `validate_config/1`: the caller that needs connectivity
  # (`Calendar.Creation.prevalidate_config/1`) invokes `validate_config/1` first
  # and then `perform_connection_test/1`. Folding a connectivity probe into this
  # callback would double-charge a rate-limited connection test that runs both
  # in sequence.
  @impl Tymeslot.Integrations.Calendar.Provider
  def validate_config(config) do
    with :ok <-
           ProviderConfigHelper.validate_required_fields(config, [:base_url, :username, :password]) do
      ProviderCommon.validate_caldav_url(
        :zimbra,
        config[:base_url],
        dgettext(
          "dashboard_calendar_providers",
          "Invalid Zimbra URL. Should be your Zimbra server URL (e.g., https://mail.example.com) or full CalDAV URL (e.g., https://mail.example.com/dav/user@example.com)"
        )
      )
    end
  end

  @impl Tymeslot.Integrations.Calendar.Provider
  def new(config) do
    CaldavCommon.build_provider_client(
      config,
      :zimbra,
      normalize_base_url(config[:base_url]),
      build_zimbra_calendar_paths(config)
    )
  end

  @doc """
  Tests connection to Zimbra server with Zimbra-specific messaging.
  """
  @impl Tymeslot.Integrations.Calendar.Provider
  @spec perform_connection_test(map()) :: {:ok, String.t()} | {:error, term()}
  def perform_connection_test(integration) do
    ProviderCommon.test_caldav_provider_connection(integration,
      success_message: dgettext("dashboard_calendar_providers", "Zimbra connection successful"),
      not_found_message:
        dgettext(
          "dashboard_calendar_providers",
          "Zimbra server not found. Check your server URL."
        ),
      error_formatter: &format_error/1
    )
  end

  @doc """
  Discovers available calendars on the Zimbra server.
  """
  @impl Tymeslot.Integrations.Calendar.Provider
  @spec discover_calendars(map()) :: {:ok, [CalendarEntry.t()]} | {:error, String.t()}
  def discover_calendars(client) do
    # Ensure provider is set to zimbra for proper discovery URL
    client = Map.put(client, :provider, :zimbra)

    CaldavCommon.discover_calendars(client)
  end

  @impl Tymeslot.Integrations.Calendar.Provider
  def discover_calendars_for_integration(integration),
    do: ProviderCommon.caldav_discover_from_integration(__MODULE__, integration)

  @impl Tymeslot.Integrations.Calendar.Provider
  defdelegate build_client_configs(integration),
    to: ProviderCommon,
    as: :caldav_build_client_configs

  @impl Tymeslot.Integrations.Calendar.Provider
  defdelegate build_booking_client_config(integration),
    to: ProviderCommon,
    as: :caldav_build_booking_client_config

  @impl Tymeslot.Integrations.Calendar.Provider
  def create_event(client, event_data), do: CaldavCommon.create_event(client, event_data)

  @impl Tymeslot.Integrations.Calendar.Provider
  def update_event(client, uid, event_data),
    do: CaldavCommon.update_event(client, uid, event_data)

  @impl Tymeslot.Integrations.Calendar.Provider
  def delete_event(client, uid, opts), do: CaldavCommon.delete_event(client, uid, opts)

  @impl Tymeslot.Integrations.Calendar.Provider
  def fetch_event(client, event_ref), do: CaldavCommon.fetch_event(client, event_ref)

  @impl Tymeslot.Integrations.Calendar.Provider
  def find_moved_event(client, event_ref), do: CaldavCommon.find_moved_event(client, event_ref)

  @impl Tymeslot.Integrations.Calendar.Provider
  def list_events(client, opts), do: CaldavCommon.list_events(client, opts)

  @impl Tymeslot.Integrations.Calendar.Provider
  def list_events_representation, do: :raw

  @impl Tymeslot.Integrations.Calendar.Provider
  def normalise_events(raw_events, context),
    do: EventProcessor.normalise_events(raw_events, context)

  @impl Tymeslot.Integrations.Calendar.Provider
  def check_connectivity(client), do: CaldavCommon.check_connectivity(client)

  # Private helper functions

  defp normalize_base_url(url) do
    url
    |> String.trim()
    |> String.trim_trailing("/")
  end

  defp build_zimbra_calendar_paths(config) do
    case config[:calendar_paths] do
      paths when is_list(paths) -> paths
      _other -> []
    end
  end

  defp format_error(error), do: ErrorHandler.sanitize_error_message(error, :zimbra)
end
