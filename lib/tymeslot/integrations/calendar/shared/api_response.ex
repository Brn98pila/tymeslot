defmodule Tymeslot.Integrations.Calendar.Shared.ApiResponse do
  @moduledoc """
  Shared HTTP response handling for the JSON calendar API clients.

  Google Calendar and Microsoft Graph return different error vocabularies, but
  the envelope around them is the same: decode a JSON body on success, treat a
  401 as an expired token, refine a bare 404 using the request path, and fall
  back to a redacted log line plus an opaque message for anything else.

  Centralising that envelope is a safety property rather than a tidiness one.
  The generic fallback is the only place a raw provider body is logged, so it
  is the only place redaction can be forgotten. A provider that handles its own
  statuses inline would have to remember `Redactor.redact_and_truncate/1` every
  time; routing through here means it cannot be skipped.

  Providers keep what genuinely differs, passing it as `:custom`: Google
  classifies a 403 from `error.errors[].reason`, Graph from `error.code` plus a
  `Retry-After` header, and only Graph reports throttling as a bare 429.
  """

  require Logger

  alias Tymeslot.Infrastructure.Logging.Redactor
  alias Tymeslot.Integrations.Calendar.HTTP
  alias Tymeslot.Integrations.Shared.OAuth.ErrorParser
  alias Tymeslot.Integrations.Shared.OAuth.TokenEndpoint

  import ErrorParser, only: [is_oauth_error_status: 1]

  @typedoc """
  The three-element error shape both calendar API clients return: a machine
  readable reason alongside a message safe to surface to the caller.
  """
  @type result :: {:ok, map()} | {:error, atom(), String.t()}

  @doc """
  Handles a response whose 404 should name the missing resource.

  A bare 404 means "calendar" on a calendar-scoped path and "event" on an
  event-scoped one; only the request path, which the caller has in scope, can
  tell them apart.
  """
  @spec handle(term(), String.t(), keyword()) :: result()
  def handle(response, path, opts) do
    case handle(response, opts) do
      {:error, :not_found, _generic} -> {:error, :not_found, HTTP.not_found_message(path)}
      result -> result
    end
  end

  @doc """
  Handles a response, giving the provider first refusal on the status.

  ## Options

    * `:label` — provider name used in the fallback log line, e.g.
      `"Google Calendar"`. **Required.**
    * `:custom` — a `(response -> result | :default)` consulted before the
      shared clauses. Returning `:default` accepts the shared handling.
  """
  @spec handle(term(), keyword()) :: result()
  def handle(response, opts) do
    label = Keyword.fetch!(opts, :label)
    custom = Keyword.get(opts, :custom, fn _response -> :default end)

    case custom.(response) do
      :default -> default_handle(response, label)
      result -> result
    end
  end

  @doc """
  Decodes a provider error body and hands its `error` object to `fun`.

  Both providers nest the human-readable text at `error.message` and their
  classification hints as siblings of it, so the decode-and-reach step is
  shared while the classification stays with the provider. A body that will not
  decode cannot be classified, so it short-circuits to a network error.
  """
  @spec with_error_object(binary(), (String.t(), map() -> result())) :: result()
  def with_error_object(body, fun) do
    case Jason.decode(body) do
      {:ok, decoded} ->
        fun.(get_in(decoded, ["error", "message"]) || "Forbidden", decoded)

      {:error, _reason} ->
        {:error, :network_error, "Forbidden (malformed response)"}
    end
  end

  @doc """
  Maps a token endpoint refresh onto the calendar clients' refresh result.

  A 400 or 401 is the provider refusing the credential, and its message keeps
  the OAuth error code so the refresh job and the health check can tell a
  revoked grant (`invalid_grant`) from other refusals. Anything else, a 200
  that did not decode included, is transient, and missing client credentials
  are an authentication error.
  """
  @spec token_refresh({:ok, TokenEndpoint.tokens()} | {:error, TokenEndpoint.refresh_error()}) ::
          {:ok, {String.t(), String.t(), DateTime.t()}} | {:error, atom(), String.t()}
  def token_refresh(
        {:ok, %{access_token: access, refresh_token: refresh, expires_at: expires_at}}
      ),
      do: {:ok, {access, refresh, expires_at}}

  def token_refresh({:error, {:http_error, status, body}}) when is_oauth_error_status(status),
    do: {:error, :unauthorized, ErrorParser.build_message("Token refresh failed", status, body)}

  def token_refresh({:error, {:http_error, status, _body}}),
    do: {:error, :network_error, "HTTP #{status}"}

  def token_refresh({:error, {:network_error, reason}}),
    do: {:error, :network_error, "Network error: #{inspect(reason)}"}

  def token_refresh({:error, {:not_configured, message}}),
    do: {:error, :authentication_error, message}

  defp default_handle({:ok, %{status: status, body: body}}, _label)
       when status in [200, 201, 204] do
    decode_body(body)
  end

  defp default_handle({:ok, %{status: 401}}, _label) do
    {:error, :unauthorized, "Token expired or invalid"}
  end

  defp default_handle({:ok, %{status: 404}}, _label) do
    {:error, :not_found, "Calendar not found"}
  end

  # The only path that sees an unrecognised provider body, and so the only one
  # that has to redact. The caller gets an opaque message: the detail is in the
  # logs, where it is truncated and stripped of credentials.
  defp default_handle({:ok, %{status: status, body: body}}, label) do
    Logger.error("Calendar API error",
      provider: label,
      status: status,
      body: Redactor.redact_and_truncate(body)
    )

    {:error, :network_error, "HTTP #{status} (see logs for details)"}
  end

  defp default_handle({:error, reason}, _label) do
    {:error, :network_error, "Network error: #{inspect(reason)}"}
  end

  defp decode_body(""), do: {:ok, %{}}

  defp decode_body(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _reason} -> {:error, :network_error, "Malformed JSON response"}
    end
  end
end
