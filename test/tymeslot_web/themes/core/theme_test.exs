defmodule TymeslotWeb.Themes.Core.ThemeTest.Fixture.Meeting.Reschedule do
  @moduledoc false
  @spec render(map()) :: {atom(), map()}
  def render(assigns), do: {:reschedule, assigns}
end

defmodule TymeslotWeb.Themes.Core.ThemeTest.Fixture.Meeting.Cancel do
  @moduledoc false
  @spec render(map()) :: {atom(), map()}
  def render(assigns), do: {:cancel, assigns}
end

defmodule TymeslotWeb.Themes.Core.ThemeTest.Fixture.Meeting.CancelConfirmed do
  @moduledoc false
  @spec render(map()) :: {atom(), map()}
  def render(assigns), do: {:cancel_confirmed, assigns}
end

defmodule TymeslotWeb.Themes.Core.ThemeTest.Fixture.Poll.Voting do
  @moduledoc false
  @spec render(map()) :: {atom(), map()}
  def render(assigns), do: {:poll, assigns}
end

defmodule TymeslotWeb.Themes.Core.ThemeTest.Fixture.Payment.Processing do
  @moduledoc false
  @spec render(map()) :: {atom(), map()}
  def render(assigns), do: {:processing, assigns}
end

defmodule TymeslotWeb.Themes.Core.ThemeTest.Fixture.Payment.Cancelled do
  @moduledoc false
  @spec render(map()) :: {atom(), map()}
  def render(assigns), do: {:cancelled, assigns}
end

defmodule TymeslotWeb.Themes.Core.ThemeTest.Fixture.Theme do
  @moduledoc false
  use TymeslotWeb.Themes.Core.Theme,
    live_view: TymeslotWeb.Themes.Core.ThemeTest.Fixture.Live,
    preview_image: "/images/fixture.webp",
    description:
      dgettext_noop(
        "dashboard_appearance",
        "Modern sliding design with video background and a 4-slide booking flow."
      )
end

defmodule TymeslotWeb.Themes.Core.ThemeTest.Overriding.Theme do
  @moduledoc false
  use TymeslotWeb.Themes.Core.Theme,
    live_view: TymeslotWeb.Themes.Core.ThemeTest.Overriding.Live,
    preview_image: "/images/fixture.webp",
    description:
      dgettext_noop(
        "dashboard_appearance",
        "Modern sliding design with video background and a 4-slide booking flow."
      )

  @impl TymeslotWeb.Themes.Core.Behaviour
  def render_poll_action(_assigns), do: :overridden

  @impl TymeslotWeb.Themes.Core.Behaviour
  def render_meeting_action(_assigns, _action), do: :overridden

  @impl TymeslotWeb.Themes.Core.Behaviour
  def render_payment_page(_assigns, _page), do: :overridden
end

defmodule TymeslotWeb.Themes.Core.ThemeTest do
  use ExUnit.Case, async: true

  @moduletag :themes
  @moduletag :unit

  alias TymeslotWeb.Themes.Core.ThemeTest.Fixture.Theme, as: Fixture
  alias TymeslotWeb.Themes.Core.ThemeTest.Overriding.Theme, as: Overriding

  @assigns %{marker: :assigns}

  test "declares the theme behaviour" do
    behaviours = Keyword.get_values(Fixture.module_info(:attributes), :behaviour)
    assert TymeslotWeb.Themes.Core.Behaviour in List.flatten(behaviours)
  end

  test "live_view_module/0 returns the :live_view option" do
    assert Fixture.live_view_module() == TymeslotWeb.Themes.Core.ThemeTest.Fixture.Live
  end

  test "metadata/0 carries the preview image and the translated description" do
    Gettext.put_locale(TymeslotWeb.Gettext, "de")

    assert %{preview_image: "/images/fixture.webp", description: description} =
             Fixture.metadata()

    assert description ==
             Gettext.dgettext(
               TymeslotWeb.Gettext,
               "dashboard_appearance",
               "Modern sliding design with video background and a 4-slide booking flow."
             )

    refute description =~ "Modern sliding design"
  end

  test "render_meeting_action/2 dispatches to the theme's Meeting modules" do
    assert Fixture.render_meeting_action(@assigns, :reschedule) == {:reschedule, @assigns}
    assert Fixture.render_meeting_action(@assigns, :cancel) == {:cancel, @assigns}

    assert Fixture.render_meeting_action(@assigns, :cancel_confirmed) ==
             {:cancel_confirmed, @assigns}

    assert_raise RuntimeError, "Unsupported meeting action: invalid", fn ->
      Fixture.render_meeting_action(@assigns, :invalid)
    end
  end

  test "render_poll_action/1 dispatches to the theme's Poll.Voting" do
    assert Fixture.render_poll_action(@assigns) == {:poll, @assigns}
  end

  test "render_payment_page/2 dispatches to the theme's Payment modules" do
    assert Fixture.render_payment_page(@assigns, :processing) == {:processing, @assigns}
    assert Fixture.render_payment_page(@assigns, :cancelled) == {:cancelled, @assigns}
  end

  test "every render callback can be overridden" do
    assert Overriding.render_poll_action(@assigns) == :overridden
    assert Overriding.render_meeting_action(@assigns, :cancel) == :overridden
    assert Overriding.render_payment_page(@assigns, :processing) == :overridden
  end

  # The macro under test runs inside Code.compile_string/1, where the check
  # cannot see it.
  # credo:disable-for-next-line Jump.CredoChecks.VacuousTest
  test "rejects a description that is not a dgettext_noop/2 call" do
    assert_raise ArgumentError, ~r/dgettext_noop/, fn ->
      Code.compile_string("""
      defmodule TymeslotWeb.Themes.Core.ThemeTest.BadDescription.Theme do
        use TymeslotWeb.Themes.Core.Theme,
          live_view: Some.Live,
          preview_image: "/images/fixture.webp",
          description: "not translatable"
      end
      """)
    end
  end
end
