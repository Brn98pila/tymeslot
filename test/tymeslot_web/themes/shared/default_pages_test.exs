defmodule TymeslotWeb.Themes.Shared.DefaultPagesTest do
  @moduledoc """
  The pages a theme gets from `use TymeslotWeb.Themes.Core.Theme,
  page_shell: ...`: each shared body inside the theme's shell, the shell
  told which page it is drawing.
  """

  use ExUnit.Case, async: true

  @moduletag :themes

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias TymeslotWeb.Test.FixtureTheme.Theme, as: FixtureTheme
  alias TymeslotWeb.ThemeCommonTestCases

  defp assigns, do: Map.put(ThemeCommonTestCases.build_meeting_assigns("99"), :theme_id, "99")

  defp html(rendered), do: rendered_to_string(rendered)

  test "draws each meeting page inside the theme's shell, naming the page" do
    for {action, page} <- [
          reschedule: "reschedule",
          cancel: "cancel",
          cancel_confirmed: "cancel_confirmed"
        ] do
      out = html(FixtureTheme.render_meeting_action(assigns(), action))
      assert out =~ ~s(data-testid="fixture-page-shell"), "#{action} is not in the shell"
      assert out =~ ~s(data-page="#{page}")
      assert out =~ ~s(class="manage-page manage-page--)
    end
  end

  test "the cancel page sends the dispatcher's events" do
    out = html(FixtureTheme.render_meeting_action(assigns(), :cancel))
    assert out =~ ~s(phx-click="cancel_meeting")
    assert out =~ ~s(phx-click="keep_meeting")
    assert out =~ ~s(data-testid="cancel-meeting")
  end

  test "the reschedule page leads to the organiser's booking page for this meeting" do
    out =
      assigns()
      |> Map.put(:meeting_uid, "m-42")
      |> FixtureTheme.render_meeting_action(:reschedule)
      |> html()

    assert out =~ "/testuser?reschedule_meeting_uid=m-42"
  end

  test "the payment pages carry the theme's own test id, from the page's theme" do
    base = %{loading: true, payment: nil, meeting: nil, rebook_path: nil, theme_id: "99"}

    assert html(FixtureTheme.render_payment_page(base, :processing)) =~
             ~s(data-testid="fixture-payment-processing")

    assert html(FixtureTheme.render_payment_page(base, :cancelled)) =~
             ~s(data-testid="fixture-payment-cancelled")
  end

  test "the shell gets no customisation and no locale on a payment page" do
    base = %{loading: false, payment: nil, meeting: nil, rebook_path: "/x", theme_id: "99"}
    out = html(FixtureTheme.render_payment_page(base, :cancelled))

    assert out =~ ~s(data-page="payment_cancelled")
    refute out =~ "<style"
  end

  test "an unknown meeting action raises as the conventional default does" do
    assert_raise RuntimeError, "Unsupported meeting action: invalid", fn ->
      FixtureTheme.render_meeting_action(assigns(), :invalid)
    end
  end
end
