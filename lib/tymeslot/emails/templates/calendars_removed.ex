defmodule Tymeslot.Emails.Templates.CalendarsRemoved do
  @moduledoc """
  MJML email template telling the owner of a calendar integration that the
  calendar server no longer has one or more of the calendars Tymeslot used,
  so Tymeslot has stopped using them.

  One email per deselection, listing every calendar that deselection
  removed; the dashboard shows the same notice until the owner dismisses it
  (see `Tymeslot.Integrations.Calendar.RemovedCalendars`).

  Rendered in the owner's locale. The caller establishes it with
  `Tymeslot.Emails.RecipientLocale`.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Emails.Shared.{Buttons, Callouts, Sanitise, Styles, TemplateHelper, Text}
  alias Tymeslot.Utils.UrlBuilder

  @intent :alert

  @doc "The subject line, in the current locale."
  @spec subject([String.t()]) :: String.t()
  def subject([calendar]) do
    dgettext("emails_integrations", "“%{calendar}” is no longer on your calendar server",
      calendar: calendar
    )
  end

  def subject(calendars) do
    dngettext(
      "emails_integrations",
      "%{count} calendar is no longer on your calendar server",
      "%{count} calendars are no longer on your calendar server",
      length(calendars)
    )
  end

  @doc "Returns `{html_body, text_body}`."
  @spec render_both(%{required(:name) => String.t(), optional(atom()) => term()}, [String.t()]) ::
          {String.t(), String.t()}
  def render_both(integration, [_first | _rest] = calendars) do
    copy = copy(integration, calendars)
    {render_html(copy), render_text(copy)}
  end

  defp render_html(copy) do
    mjml_content = """
    #{Callouts.alert_box(:alert, copy.reason, title: copy.title, items: list_items(copy.calendars))}

    #{Text.title_section(dgettext("emails_integrations", "What's happening?"))}

    <mj-text
      font-size="16px"
      color="#{Styles.ink_soft()}"
      line-height="1.5"
      align="left"
      css-class="mobile-text"
    >
      #{Sanitise.sanitize_for_email(copy.happening)}
    </mj-text>

    #{Text.divider()}

    #{Text.title_section(dgettext("emails_integrations", "What should I do?"))}

    <mj-text color="#{Styles.ink_soft()}" font-size="14px" line-height="1.6">
      #{copy.action}
    </mj-text>

    #{Buttons.action_button(@intent, copy.button, copy.settings_url)}

    #{Text.divider()}

    #{Text.system_footer_note(copy.footer)}
    """

    TemplateHelper.compile_system_template(mjml_content, copy.title, copy.subject,
      intent: @intent,
      eyebrow: dgettext("emails_integrations", "Integration"),
      stage_title: copy.title,
      stage_subtitle: copy.subject
    )
  end

  defp render_text(copy) do
    """
    #{copy.title}

    #{copy.reason}
    #{Enum.map_join(list_items(copy.calendars), "", &("\n- " <> &1))}

    #{String.upcase(dgettext("emails_integrations", "What's happening?"))}
    #{copy.happening}

    #{String.upcase(dgettext("emails_integrations", "What should I do?"))}
    #{copy.action}

    #{copy.button}:
    #{copy.settings_url}

    #{copy.footer}
    """
  end

  defp copy(integration, calendars) do
    count = length(calendars)

    %{
      calendars: calendars,
      title:
        dngettext(
          "emails_integrations",
          "Calendar no longer available",
          "Calendars no longer available",
          count
        ),
      subject: subject(calendars),
      reason: reason(calendars),
      happening:
        dngettext(
          "emails_integrations",
          "Tymeslot checked %{integration} and the server no longer has the calendar listed above. This usually means it was deleted, or stopped being shared with you, on the server. Your other calendars on %{integration} are unaffected.",
          "Tymeslot checked %{integration} and the server no longer has the calendars listed above. This usually means they were deleted, or stopped being shared with you, on the server. Your other calendars on %{integration} are unaffected.",
          count,
          integration: integration.name
        ),
      action:
        dngettext(
          "emails_integrations",
          "If you removed it on purpose, there is nothing to do. If not, restore it on your calendar server, then select it again in your calendar settings.",
          "If you removed them on purpose, there is nothing to do. If not, restore them on your calendar server, then select them again in your calendar settings.",
          count
        ),
      button: dgettext("emails_integrations", "Open calendar settings"),
      settings_url: UrlBuilder.build_url("/dashboard/integrations?tab=calendars"),
      footer:
        dgettext(
          "emails_integrations",
          "You get this email once each time a calendar disappears. The notice in your calendar settings stays until you dismiss it."
        )
    }
  end

  defp reason([calendar]) do
    dgettext(
      "emails_integrations",
      "“%{calendar}” is no longer on your calendar server, so Tymeslot has stopped using it.",
      calendar: calendar
    )
  end

  defp reason(_calendars) do
    dgettext(
      "emails_integrations",
      "These calendars are no longer on your calendar server, so Tymeslot has stopped using them:"
    )
  end

  # One calendar is named in the reason itself; several are listed under it.
  defp list_items([_calendar]), do: []
  defp list_items(calendars), do: calendars
end
