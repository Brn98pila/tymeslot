defmodule Tymeslot.Integrations.Common.ErrorHandler do
  @moduledoc """
  Standardized error handling for all integration modules.

  This module provides consistent error formatting, logging, and handling patterns
  across all calendar and video integration providers.
  """

  require Logger

  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Infrastructure.Logging.Redactor

  @doc """
  Wraps a function call with standardized error handling and logging.

  This function executes the provided function and handles any errors
  with consistent logging and error formatting.

  ## Options

    * `:operation` - A string describing the operation being performed (for logging)
    * `:provider` - The provider name (for logging context)
    * `:log_level` - The log level to use for errors (default: :error)
    * `:suppress_errors` - List of error reasons to suppress from logging

  ## Examples

      handle_with_logging(fn ->
        SomeAPI.call()
      end, operation: "fetch calendar events", provider: "google")
  """
  @spec handle_with_logging((-> any()), keyword()) :: any()
  def handle_with_logging(fun, opts \\ []) when is_function(fun, 0) do
    operation = Keyword.get(opts, :operation, "unknown operation")
    provider = Keyword.get(opts, :provider, "unknown provider")
    log_level = Keyword.get(opts, :log_level, :error)
    suppress_errors = Keyword.get(opts, :suppress_errors, [])

    try do
      case fun.() do
        {:ok, result} ->
          {:ok, result}

        {:error, reason} = error ->
          unless reason in suppress_errors do
            log_error(log_level, operation, provider, reason)
          end

          error

        {:error, _type, reason} ->
          unless reason in suppress_errors do
            log_error(log_level, operation, provider, reason)
          end

          {:error, reason}

        other ->
          Logger.warning("Unexpected return value from integration operation",
            operation: operation,
            provider: provider,
            value: LogFormat.reason(other)
          )

          other
      end
    rescue
      exception ->
        error_reason = Exception.message(exception)
        log_error(log_level, operation, provider, error_reason, exception)
        {:error, error_reason}
    end
  end

  @doc """
  Creates a standardized error message for integration failures.

  ## Examples

      iex> format_integration_error("google", "authentication", "invalid token")
      "Google integration failed during authentication: invalid token"
  """
  @spec format_integration_error(String.t(), String.t(), String.t()) :: String.t()
  def format_integration_error(provider, operation, reason) do
    provider_name = String.capitalize(provider)
    "#{provider_name} integration failed during #{operation}: #{reason}"
  end

  # Private functions

  defp log_error(level, operation, provider, reason, exception \\ nil) do
    base_message =
      "Integration error during #{operation} (#{provider}): #{Redactor.redact(reason)}"

    if exception do
      Logger.log(level, [base_message, "\n", Redactor.redact(exception)])
    else
      Logger.log(level, base_message)
    end
  end
end
