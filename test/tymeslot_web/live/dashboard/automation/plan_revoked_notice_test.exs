defmodule TymeslotWeb.Dashboard.Automation.PlanRevokedNoticeTest do
  # An integration switched off because the plan no longer covers automations
  # says so in the owner's language on every automation card.
  use TymeslotWeb.ConnCase, async: true

  @moduletag :automation

  import Phoenix.LiveViewTest
  import Tymeslot.Factory

  alias TymeslotWeb.Dashboard.Automation.{SlackCard, TelegramCard, WebhookCard}

  @handlers %{
    time_format: "24h",
    target: "#card",
    on_edit: "edit",
    on_delete: "delete",
    on_toggle: "toggle",
    on_test: "test",
    on_view_deliveries: "logs",
    on_reenable: "reenable"
  }

  @disabled %{
    id: 1,
    is_active: false,
    disabled_at: ~U[2026-10-01 09:00:00Z],
    disabled_reason: "plan_revoked"
  }

  setup do
    Gettext.put_locale(TymeslotWeb.Gettext, "de")
    :ok
  end

  defp render_card(fun, assigns), do: render_component(fun, Map.merge(@handlers, assigns))

  test "the Slack card" do
    html =
      render_card(&SlackCard.slack_card/1, %{
        integration: build(:slack_integration, @disabled)
      })

    assert html =~ "Ihr Tarif umfasst keine Automatisierungen mehr"
    refute html =~ "plan_revoked"
  end

  test "the Telegram card, including one switched off under the old English reason" do
    for reason <- ["plan_revoked", "Plan no longer permits automations"] do
      attrs = Map.merge(@disabled, %{disabled_reason: reason, status: :auto_disabled})
      integration = build(:telegram_integration, attrs)

      html = render_card(&TelegramCard.telegram_card/1, %{integration: integration})

      assert html =~ "Ihr Tarif umfasst keine Automatisierungen mehr"
      refute html =~ reason
    end
  end

  test "the webhook card" do
    html = render_card(&WebhookCard.webhook_card/1, %{webhook: build(:webhook, @disabled)})

    assert html =~ "Ihr Tarif umfasst keine Automatisierungen mehr"
    refute html =~ "plan_revoked"
  end
end
