defmodule TymeslotWeb.Themes.Quill.Scheduling.Live do
  @moduledoc """
  Quill theme scheduling LiveView with 4-step glassmorphism flow:
  1. Overview (duration selection)
  2. Schedule (calendar and time selection)
  3. Booking (form input)
  4. Confirmation (thank you page)
  """
  use TymeslotWeb.Themes.Shared.SchedulingLive, theme_id: "1"

  alias TymeslotWeb.Themes.Quill.Scheduling.Components.{
    BookingComponent,
    ConfirmationComponent,
    CustomQuestionsComponent,
    OverviewComponent,
    ScheduleComponent
  }

  alias TymeslotWeb.Themes.Quill.Scheduling.Wrapper, as: QuillThemeWrapper
  alias TymeslotWeb.Themes.Shared.Components.AwaitingPayment

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <QuillThemeWrapper.quill_wrapper
      custom_css={assigns[:custom_css]}
      theme_customization={assigns[:theme_customization]}
      locale={assigns[:locale]}
      language_dropdown_open={assigns[:language_dropdown_open]}
      current_state={assigns[:current_state]}
      organizer_user_id={@organizer_user_id}
      owner_preview={assigns[:owner_preview]}
      should_show_branding={assigns[:should_show_branding]}
    >
      <%= if assigns[:scheduling_error_message] do %>
        <.live_component
          module={ErrorComponent}
          id="scheduling-error"
          message={@scheduling_error_message}
        />
      <% else %>
        <%= case assigns[:current_state] || :overview do %>
          <% :overview -> %>
            <.live_component module={OverviewComponent} id="overview-step" {assigns} />
          <% :schedule -> %>
            <.live_component module={ScheduleComponent} id="schedule-step" {assigns} />
          <% :questions -> %>
            <.live_component module={CustomQuestionsComponent} id="questions-step" {assigns} />
          <% :booking -> %>
            <.live_component module={BookingComponent} id="booking-step" {assigns} />
          <% :awaiting_payment -> %>
            <AwaitingPayment.awaiting_payment checkout_url={@awaiting_payment_checkout_url} />
          <% :confirmation -> %>
            <.live_component module={ConfirmationComponent} id="confirmation-step" {assigns} />
          <% _ -> %>
            <.live_component module={OverviewComponent} id="overview-step" {assigns} />
        <% end %>
      <% end %>
    </QuillThemeWrapper.quill_wrapper>
    """
  end
end
