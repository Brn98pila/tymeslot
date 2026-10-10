defmodule Tymeslot.Emails.Templates.IntegrationReauthRequired do
  @moduledoc """
  MJML email template telling a user that one of their integrations has stopped
  being usable and only reconnecting will fix it.

  Distinct from `Tymeslot.Emails.Templates.IntegrationUnhealthy`, which reports
  intermittent probe failures that may already have resolved themselves. This
  one is sent when the cause is known and permanent until the user acts: a
  revoked grant, scopes that no longer cover what Tymeslot must do, rejected
  credentials, or a calendar setup with nothing left to sync into. Saying "may
  need attention" about a certainty would understate it.

  The reason shown is the integration's stored `sync_error`: the English
  source of the sentence the dashboard shows translated, so the two cannot
  drift apart. The rest of the copy stays true for every cause, because the
  reason is the only part that varies.

  The steps follow the actions the integration's dashboard row actually has.
  A calendar row and an OAuth video row have a Reconnect button. A video
  integration holding credentials the user typed in (Jitsi, Nextcloud Talk) is
  fixed from its Edit button instead. A calendar subscription has neither: its
  feed link is the whole connection, so it is removed and subscribed to again
  with the current link.

  Rendered in the recipient's locale.
  """

  alias Swoosh.Email
  alias Tymeslot.Emails.RecipientLocale
  alias Tymeslot.Emails.Shared.{IntegrationLabels, IntegrationNotice}
  alias Tymeslot.Integrations.Calendar.ProviderConfig, as: CalendarProviderConfig
  alias Tymeslot.Integrations.Video.ProviderConfig, as: VideoProviderConfig

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
    provider = IntegrationLabels.provider_name(integration, kind)
    name = IntegrationLabels.integration_name(integration, kind)
    fix = fix(integration, kind, provider, name)

    %{
      subject: "Reconnect your #{provider} integration",
      title: "Reconnect required",
      preheader: "Your #{name} integration needs reconnecting",
      subtitle: "Your #{name} integration needs reconnecting before it can keep working.",
      eyebrow: "Integration",
      reason: reason_for(integration, provider),
      happening_heading: "What's happening?",
      happening: {fix.happening, name},
      next_heading: "What should I do?",
      next: fix.steps,
      button: fix.button,
      settings_url: IntegrationLabels.settings_url(kind),
      footer: fix.footer
    }
  end

  # The stored reason is written for the dashboard badge and already names the
  # provider and the action. A blank one means the flag was set by a path that
  # recorded no diagnosis, so fall back to something true rather than empty.
  defp reason_for(%{sync_error: reason}, provider) when is_binary(reason) do
    if String.trim(reason) == "", do: default_reason(provider), else: reason
  end

  defp reason_for(_integration, provider), do: default_reason(provider)

  defp default_reason(provider),
    do: "#{provider} needs reconnecting before Tymeslot can use it again."

  # A video integration outside the OAuth family has no Reconnect button: its
  # credentials were typed in, and they are replaced from the Edit dialog.
  defp fix(integration, :video, provider, name) do
    if VideoProviderConfig.oauth_provider?(integration.provider),
      do: reconnect_fix(provider, name),
      else: edit_fix(provider, name)
  end

  # A subscription row has no Reconnect button: a revoked feed link is replaced
  # by removing the row and subscribing again.
  defp fix(integration, :calendar, provider, name) do
    if CalendarProviderConfig.subscription?(integration.provider),
      do: subscription_fix(provider, name),
      else: reconnect_fix(provider, name)
  end

  defp fix(_integration, _kind, provider, name), do: reconnect_fix(provider, name)

  # The owner is not told again while the integration stays flagged: the reauth
  # email goes out when the flag is set, and the unhealthy email is withheld
  # from a flagged integration. Each fix says so with its own verb.
  defp reconnect_fix(provider, name) do
    %{
      happening:
        "Tymeslot can no longer use your #{name} integration, and it will stay that way until you reconnect it. The reason is shown above. Your existing bookings are not affected.",
      steps: [
        "Open your integration settings",
        {"Select Reconnect on the #{provider} row", "Reconnect"},
        "Follow the steps #{provider} asks for"
      ],
      button: "Reconnect #{provider}",
      footer:
        "This notification is sent when an integration needs attention. You will not receive another notice about this until you reconnect it."
    }
  end

  defp edit_fix(provider, name) do
    %{
      happening:
        "Tymeslot can no longer use your #{name} integration, and it will stay that way until you update it. The reason is shown above. Your existing bookings are not affected.",
      steps: [
        "Open your integration settings",
        {"Select Edit on the #{provider} row", "Edit"},
        "Enter the credentials again, or new ones if the old ones were revoked, and save"
      ],
      button: "Edit #{provider}",
      footer:
        "This notification is sent when an integration needs attention. You will not receive another notice about this until you update it."
    }
  end

  defp subscription_fix(provider, name) do
    %{
      happening:
        "Tymeslot can no longer use your #{name} integration, and it will stay that way until you replace it. The reason is shown above. Your existing bookings are not affected.",
      steps: [
        "Open your calendar settings",
        {"Select Delete on the #{provider} row", "Delete"},
        {"Choose #{provider}, paste the current feed link and select Subscribe", provider}
      ],
      button: "Open calendar settings",
      footer:
        "This notification is sent when an integration needs attention. You will not receive another notice about this until you replace it."
    }
  end
end
