defmodule Tymeslot.Emails.Templates.IntegrationPaused do
  @moduledoc """
  Email telling a user that an integration has been automatically paused
  after the configured number of days of sustained unhealthy status
  (`:auto_pause_cutoff_days`, default 14 days).
  """

  alias Swoosh.Email
  alias Tymeslot.Emails.RecipientLocale
  alias Tymeslot.Emails.Shared.{IntegrationLabels, IntegrationNotice}

  @doc "The email, addressed and rendered in the recipient's locale."
  @spec render(
          Tymeslot.Emails.EmailService.user_map(),
          IntegrationLabels.integration(),
          IntegrationLabels.kind(),
          pos_integer()
        ) :: Email.t()
  def render(user, integration, kind, cutoff_days) do
    RecipientLocale.with_user_locale(user, fn ->
      IntegrationNotice.email(user, copy(integration, kind, cutoff_days))
    end)
  end

  defp copy(integration, kind, cutoff_days) do
    name = IntegrationLabels.integration_name(integration, kind)

    %{
      subject: subject(kind),
      title: "Integration paused",
      preheader: "Your #{name} integration has been paused",
      subtitle:
        "Your #{name} integration has been paused after #{cutoff_days} days of failed health checks.",
      eyebrow: "Integration",
      reason:
        "We've paused your #{name} integration after #{cutoff_days} days of failed health checks. Reconnect when you're ready and it'll resume.",
      happening_heading: "What's happening?",
      happening:
        {"Your #{name} integration has been failing connection checks for #{cutoff_days}+ days. We've paused it so it stops consuming resources and stops generating noise. Nothing has been deleted — your settings, calendar selections, and history are all preserved.",
         name},
      next_heading: "How do I bring it back?",
      next: [
        "Open your integration settings",
        {"Click Reconnect and supply fresh credentials, or toggle the integration back on if the underlying issue is already fixed",
         "Reconnect"},
        "If you no longer need this integration, you can simply remove it"
      ],
      button: "Open Integration Settings",
      settings_url: IntegrationLabels.settings_url(kind),
      footer:
        "This is the only paused-integration notification you'll receive for this integration. Reactivating it will reset the health monitor."
    }
  end

  defp subject(:video), do: "Your video integration has been paused"
  defp subject(_kind), do: "Your calendar integration has been paused"
end
