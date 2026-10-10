defmodule Tymeslot.Emails.Templates.IntegrationUnhealthy do
  @moduledoc """
  Email telling a user that one of their integrations has been continuously
  unhealthy for more than 48 hours.
  """

  alias Swoosh.Email
  alias Tymeslot.Emails.RecipientLocale
  alias Tymeslot.Emails.Shared.{IntegrationLabels, IntegrationNotice}

  @doc "The email, addressed and rendered in the recipient's locale."
  @spec render(
          Tymeslot.Emails.EmailService.user_map(),
          IntegrationLabels.integration(),
          IntegrationLabels.kind()
        ) :: Email.t()
  def render(user, integration, kind) do
    RecipientLocale.with_user_locale(user, fn ->
      IntegrationNotice.email(user, copy(integration, kind))
    end)
  end

  defp copy(integration, kind) do
    name = IntegrationLabels.integration_name(integration, kind)

    %{
      subject: subject(kind),
      title: "Integration may need attention",
      preheader: "Your #{name} integration may need attention",
      subtitle:
        "Health probes for your #{name} integration have been failing intermittently for 48+ hours.",
      eyebrow: "Integration",
      reason:
        "Our health checks for your #{name} integration have been returning errors on and off for at least 48 hours. It's worth taking a look in case something needs your attention.",
      happening_heading: "What's happening?",
      happening:
        {"Our connection probes to your #{name} integration have been failing intermittently for 48+ hours. The integration may already be working again — but if it isn't, syncing and new bookings could be affected, so it's worth a quick check.",
         name},
      next_heading: "What should I do?",
      next: [
        "Visit your integration settings to test the connection",
        "Check that your credentials or OAuth tokens are still valid",
        "If you changed your password recently, you may need to reconnect the integration",
        contact_provider(kind)
      ],
      button: "Check Integration Settings",
      settings_url: IntegrationLabels.settings_url(kind),
      footer:
        "This notification is sent when an integration remains unhealthy for 48+ hours. It will not repeat for 30 days."
    }
  end

  defp subject(:video), do: "Your video integration may need attention"
  defp subject(_kind), do: "Your calendar integration may need attention"

  defp contact_provider(:video), do: "Contact your video provider if the issue persists"
  defp contact_provider(_kind), do: "Contact your calendar provider if the issue persists"
end
