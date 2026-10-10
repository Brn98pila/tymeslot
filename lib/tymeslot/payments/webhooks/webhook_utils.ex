defmodule Tymeslot.Payments.Webhooks.WebhookUtils do
  @moduledoc """
  Utility functions for webhook handlers.
  """

  require Logger
  alias Tymeslot.Auth
  alias Tymeslot.Emails.Delivery
  alias Tymeslot.Infrastructure.Logging.LogFormat

  @doc """
  Fetches a user and executes a template-based email delivery.
  """
  @spec deliver_user_email(integer(), atom(), atom(), list(), keyword()) :: :ok
  def deliver_user_email(user_id, config_key, template_fun, args, opts) do
    # Every template reached from here greets the recipient by name, and
    # `Profiles.user_display_name/1` raises rather than guessing when
    # `:profile` is unloaded, so the user comes with the profile loaded.
    case Auth.get_user_with_profile(user_id) do
      {:error, :not_found} ->
        Logger.warning("User not found", user_id: user_id)
        :ok

      {:ok, user} ->
        template = Application.get_env(:tymeslot, config_key)

        if template && Code.ensure_loaded?(template) do
          email = apply(template, template_fun, [user | args])

          case Delivery.deliver(email) do
            {:ok, _metadata} ->
              Logger.info(Keyword.get(opts, :success_msg, "Email sent to user #{user_id}"))
              :ok

            {:error, reason} ->
              Logger.error(Keyword.get(opts, :error_msg, "Failed to send email to user"),
                user_id: user_id,
                reason: LogFormat.reason(reason)
              )

              :ok
          end
        else
          Logger.debug(
            Keyword.get(opts, :standalone_msg, "Template not configured (Standalone mode)")
          )

          :ok
        end
    end
  end
end
