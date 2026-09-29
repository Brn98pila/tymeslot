defmodule TymeslotWeb.Test.FixtureTheme.Meeting.Reschedule do
  @moduledoc "The fixture theme's reschedule page."
  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Test.FixtureTheme.Scheduling.Wrapper

  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <Wrapper.fixture_wrapper
      theme_tokens={@theme_tokens}
      locale={@locale}
      language_dropdown_open={@language_dropdown_open}
      show_language_switcher={true}
    >
      <section class="booker-card" data-testid="fixture-reschedule">
        <h1>{dgettext("booking_manage", "Reschedule Appointment")}</h1>
        <p>{dgettext("booking_manage", "Select a new time for your meeting")}</p>
      </section>
    </Wrapper.fixture_wrapper>
    """
  end
end

defmodule TymeslotWeb.Test.FixtureTheme.Meeting.Cancel do
  @moduledoc "The fixture theme's cancel page, and its kept-meeting state."
  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Test.FixtureTheme.Scheduling.Wrapper

  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <Wrapper.fixture_wrapper
      theme_tokens={@theme_tokens}
      locale={@locale}
      language_dropdown_open={@language_dropdown_open}
      show_language_switcher={true}
    >
      <section class="booker-card" data-testid="fixture-cancel">
        <%= if @meeting_kept do %>
          <h1>{dgettext("booking_manage", "Meeting Confirmed")}</h1>
          <p>{dgettext("booking_manage", "Great! Your meeting is still scheduled as planned.")}</p>
        <% else %>
          <h1>{dgettext("booking_manage", "Cancel Appointment")}</h1>
          <p>{dgettext("booking_manage", "Are you sure you want to cancel this appointment?")}</p>
          <button type="button" phx-click="cancel_meeting" data-testid="cancel-meeting">
            {dgettext("booking_manage", "Yes, Cancel Meeting")}
          </button>
          <button type="button" phx-click="keep_meeting" data-testid="keep-meeting">
            {dgettext("booking_manage", "Keep Meeting")}
          </button>
        <% end %>
      </section>
    </Wrapper.fixture_wrapper>
    """
  end
end

defmodule TymeslotWeb.Test.FixtureTheme.Meeting.CancelConfirmed do
  @moduledoc "The fixture theme's cancel-confirmed page."
  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Test.FixtureTheme.Scheduling.Wrapper

  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <Wrapper.fixture_wrapper
      theme_tokens={@theme_tokens}
      locale={@locale}
      language_dropdown_open={@language_dropdown_open}
      show_language_switcher={true}
    >
      <section class="booker-card" data-testid="fixture-cancel-confirmed">
        <h1>{dgettext("booking_manage", "Meeting Cancelled")}</h1>
        <p>{dgettext("booking_manage", "Your meeting has been successfully cancelled.")}</p>
        <.link navigate="/">{dgettext("booking_manage", "Schedule a New Meeting")}</.link>
      </section>
    </Wrapper.fixture_wrapper>
    """
  end
end

defmodule TymeslotWeb.Test.FixtureTheme.Poll.Voting do
  @moduledoc "The fixture theme's poll page: the shared poll body in its wrapper."
  use Phoenix.Component

  alias TymeslotWeb.Test.FixtureTheme.Scheduling.Wrapper
  alias TymeslotWeb.Themes.Shared.PollVotingComponents

  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <Wrapper.fixture_wrapper
      theme_tokens={@theme_tokens}
      locale={@locale}
      language_dropdown_open={@language_dropdown_open}
      show_language_switcher={true}
    >
      <section class="booker-card">
        <PollVotingComponents.poll_content
          poll={@poll}
          tallies={@tallies}
          voting_open={@voting_open}
          participant={@participant}
        />
      </section>
    </Wrapper.fixture_wrapper>
    """
  end
end

defmodule TymeslotWeb.Test.FixtureTheme.Payment.Processing do
  @moduledoc "The fixture theme's shell for the payment-processing return page."
  use Phoenix.Component

  alias TymeslotWeb.Themes.Shared.PaymentReturnComponents

  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <div class="fixture-theme-wrapper booker-page" data-testid="fixture-payment-processing">
      <section class="booker-card">
        <PaymentReturnComponents.processing_body
          loading={@loading}
          payment={@payment}
          meeting={@meeting}
          rebook_path={@rebook_path}
        />
      </section>
    </div>
    """
  end
end

defmodule TymeslotWeb.Test.FixtureTheme.Payment.Cancelled do
  @moduledoc "The fixture theme's shell for the payment-cancelled return page."
  use Phoenix.Component

  alias TymeslotWeb.Themes.Shared.PaymentReturnComponents

  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <div class="fixture-theme-wrapper booker-page" data-testid="fixture-payment-cancelled">
      <section class="booker-card">
        <PaymentReturnComponents.cancelled_body rebook_path={@rebook_path} />
      </section>
    </div>
    """
  end
end
