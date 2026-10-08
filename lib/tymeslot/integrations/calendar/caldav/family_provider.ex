defmodule Tymeslot.Integrations.Calendar.CalDAV.FamilyProvider do
  @moduledoc """
  The provider module of a CalDAV-family member that adds nothing to the
  shared CalDAV implementation but its wording.

      use Tymeslot.Integrations.Calendar.CalDAV.FamilyProvider,
        member: :radicale,
        schema: [
          base_url: "Radicale server URL (e.g., https://radicale.example.com:5232)",
          username: "Radicale username",
          password: "Radicale password",
          calendar_paths: "List of calendar UUIDs to sync (auto-discovered if not provided)"
        ],
        invalid_url_message: dgettext("dashboard_calendar_providers", "Invalid Radicale URL. ..."),
        connected_message: dgettext("dashboard_calendar_providers", "Radicale connection successful"),
        not_found_message: dgettext("dashboard_calendar_providers", "Radicale server not found. ...")

  Everything else comes from the member's row in `CalDAV.Family` (its display
  name and any fixed server address) or is the same for every member. The
  three messages are expressions evaluated on each call, so they translate
  into the caller's locale; the using module declares
  `use Gettext, backend: TymeslotWeb.Gettext` for them, ahead of this `use`.

  A failed connection test is worded by `ErrorHandler.sanitize_error_message/2`
  unless the using module defines its own private `format_error/1`.

  Nextcloud and generic CalDAV add behaviour of their own (login flow, server
  detection) and stay hand-written.
  """

  alias Tymeslot.Integrations.Calendar.CalDAV.Family
  alias Tymeslot.Integrations.Calendar.Providers.CaldavCommon
  alias Tymeslot.Integrations.Calendar.Shared.ProviderCommon
  alias Tymeslot.Integrations.Shared.ProviderConfigHelper

  @schema_keys [:base_url, :username, :password, :calendar_paths]

  defmacro __using__(opts) do
    member = Keyword.fetch!(opts, :member)
    descriptions = Keyword.fetch!(opts, :schema)

    unless Keyword.keys(descriptions) == @schema_keys,
      do: raise(ArgumentError, ":schema describes exactly #{inspect(@schema_keys)}, in order")

    quote do
      @behaviour Tymeslot.Integrations.Calendar.Provider

      alias Tymeslot.Integrations.Calendar.CalDAV.EventProcessor
      alias Tymeslot.Integrations.Calendar.CalDAV.FamilyProvider
      alias Tymeslot.Integrations.Calendar.CalendarEntry
      alias Tymeslot.Integrations.Calendar.Provider
      alias Tymeslot.Integrations.Calendar.Providers.CaldavCommon
      alias Tymeslot.Integrations.Calendar.Shared.{ErrorHandler, ProviderCommon}

      @impl Provider
      def provider_type, do: unquote(member)

      @impl Provider
      def display_name, do: unquote(Family.display_name(member))

      @impl Provider
      def connection_test_bucket, do: :caldav

      @doc "Returns the component module that renders the CalDAV-family configuration form"
      @spec setup_component() :: module()
      def setup_component,
        do: TymeslotWeb.Components.Dashboard.Integrations.Calendar.CaldavFamilyConfig

      @impl Provider
      def config_schema,
        do: unquote(Macro.escape(config_schema(member, descriptions)))

      @impl Provider
      def validate_config(config),
        do:
          FamilyProvider.validate_config(
            unquote(member),
            config,
            unquote(Keyword.fetch!(opts, :invalid_url_message))
          )

      @impl Provider
      def new(config), do: FamilyProvider.new(unquote(member), config)

      @doc """
      Tests the connection to the server, with this provider's wording.
      """
      @impl Provider
      @spec perform_connection_test(map()) :: {:ok, String.t()} | {:error, term()}
      def perform_connection_test(integration) do
        ProviderCommon.test_caldav_provider_connection(integration,
          success_message: unquote(Keyword.fetch!(opts, :connected_message)),
          not_found_message: unquote(Keyword.fetch!(opts, :not_found_message)),
          error_formatter: &format_error/1
        )
      end

      @doc """
      Discovers the calendars available on the account.
      """
      @impl Provider
      @spec discover_calendars(map()) :: {:ok, [CalendarEntry.t()]} | {:error, String.t()}
      def discover_calendars(client) do
        # The provider picks the discovery paths to try.
        client
        |> Map.put(:provider, unquote(member))
        |> CaldavCommon.discover_calendars()
      end

      @impl Provider
      def discover_calendars_for_integration(integration),
        do: ProviderCommon.caldav_discover_from_integration(__MODULE__, integration)

      @impl Provider
      defdelegate build_client_configs(integration),
        to: ProviderCommon,
        as: :caldav_build_client_configs

      @impl Provider
      defdelegate build_booking_client_config(integration),
        to: ProviderCommon,
        as: :caldav_build_booking_client_config

      @impl Provider
      defdelegate create_event(client, event_data), to: CaldavCommon

      @impl Provider
      defdelegate update_event(client, uid, event_data), to: CaldavCommon

      @impl Provider
      defdelegate delete_event(client, uid, opts), to: CaldavCommon

      @impl Provider
      defdelegate fetch_event(client, event_ref), to: CaldavCommon

      @impl Provider
      defdelegate find_moved_event(client, event_ref), to: CaldavCommon

      @impl Provider
      defdelegate list_events(client, opts), to: CaldavCommon

      @impl Provider
      def list_events_representation, do: :raw

      @impl Provider
      defdelegate normalise_events(raw_events, context), to: EventProcessor

      @impl Provider
      defdelegate check_connectivity(client), to: CaldavCommon

      defp format_error(error), do: ErrorHandler.sanitize_error_message(error, unquote(member))

      defoverridable format_error: 1
    end
  end

  @doc """
  A member's configuration schema, with the descriptions it was given. A
  member with a fixed server address offers it as the default.
  """
  @spec config_schema(Family.member(), keyword(String.t())) :: map()
  def config_schema(member, descriptions) do
    base_url =
      case Family.row!(member).fixed_url do
        nil -> %{}
        %{url: url} -> %{default: url}
      end

    %{
      base_url: Map.merge(string_field(descriptions[:base_url]), base_url),
      username: string_field(descriptions[:username]),
      password: string_field(descriptions[:password]),
      calendar_paths: %{
        type: :list,
        required: false,
        description: descriptions[:calendar_paths]
      },
      connection_timeout: timeout_field(10_000, "Connection timeout", "10 seconds"),
      request_timeout: timeout_field(30_000, "Request timeout", "30 seconds"),
      discovery_timeout: timeout_field(15_000, "Calendar discovery timeout", "15 seconds")
    }
  end

  defp string_field(description), do: %{type: :string, required: true, description: description}

  defp timeout_field(default, what, spoken) do
    %{
      type: :integer,
      required: false,
      default: default,
      description: "#{what} in milliseconds (default: #{spoken})"
    }
  end

  @doc """
  Validates a submitted configuration: the credentials are present and the
  server address passes `ProviderCommon.validate_caldav_url/3`.

  Structural validation only, in line with every other provider's
  `validate_config/1`: the caller that needs connectivity
  (`Calendar.Creation.prevalidate_config/1`) invokes `validate_config/1` first
  and then `perform_connection_test/1`. Folding a connectivity probe into this
  callback would double-charge a rate-limited connection test that runs both
  in sequence.
  """
  @spec validate_config(Family.member(), map(), String.t()) :: :ok | {:error, String.t()}
  def validate_config(member, config, invalid_url_message) do
    with :ok <-
           ProviderConfigHelper.validate_required_fields(config, [:base_url, :username, :password]) do
      ProviderCommon.validate_caldav_url(member, config[:base_url], invalid_url_message)
    end
  end

  @doc """
  Builds a member's client from a stored or submitted configuration.

  The client is built from the stored address, never repointed at a fixed
  one: a row saved before its member's address was fixed keeps syncing until
  it is reconnected. The fixed address only fills in a missing one.
  """
  @spec new(Family.member(), map()) :: CaldavCommon.caldav_client()
  def new(member, config) do
    fixed_url = Family.row!(member).fixed_url
    base_url = config[:base_url] || (fixed_url && fixed_url.url)

    calendar_paths =
      case config[:calendar_paths] do
        paths when is_list(paths) -> paths
        _other -> []
      end

    CaldavCommon.build_provider_client(
      config,
      member,
      base_url |> String.trim() |> String.trim_trailing("/"),
      calendar_paths
    )
  end
end
