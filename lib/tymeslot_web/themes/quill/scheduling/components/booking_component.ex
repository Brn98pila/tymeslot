defmodule TymeslotWeb.Themes.Quill.Scheduling.Components.BookingComponent do
  @moduledoc """
  Quill theme component for the booking/form step.
  Features glassmorphism design with elegant transparency effects.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Meetings.Approval
  alias TymeslotWeb.Live.Scheduling.OrganizerHelpers
  alias TymeslotWeb.Live.Shared.FormValidationHelpers
  alias TymeslotWeb.Themes.Shared.BookingLabels
  alias TymeslotWeb.Themes.Shared.BookingLocation
  alias TymeslotWeb.Themes.Shared.BookingText
  alias TymeslotWeb.Themes.Shared.Components.ApprovalNotice
  alias TymeslotWeb.Themes.Shared.Components.GuestField
  alias TymeslotWeb.Themes.Shared.Components.LocationField
  alias TymeslotWeb.Themes.Shared.GuestBooking
  alias TymeslotWeb.Themes.Shared.LocalizationHelpers
  alias TymeslotWeb.Themes.Shared.SecurityFields
  alias TymeslotWeb.Themes.Shared.StepEvents

  import TymeslotWeb.Components.CoreComponents

  @impl Phoenix.LiveComponent
  defdelegate update(assigns, socket), to: StepEvents

  @impl Phoenix.LiveComponent
  defdelegate handle_event(event, params, socket), to: StepEvents

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div class="container quill-container flex-1" data-locale={@locale}>
      <.page_layout
        show_steps={true}
        current_step={3}
        slug={@duration}
        username_context={@username_context}
      >
        <div class="stack">
          <div class="flex-1 flex items-center justify-center px-4 py-4">
            <div class="w-full">
              <.glass_morphism_card class="booking-form-card">
                <div class="booking-card-body">
                  <.section_header
                    level={2}
                    class="booking-heading-wrapper"
                    title_class="section-header booking-heading"
                  >
                    {dgettext("booking", "Enter Your Details")}
                  </.section_header>

                  <p class="booking-subtitle text-quill-primary">
                    <%= if @organizer_profile do %>
                      {dgettext("booking", "You're booking a %{duration} meeting with %{name}",
                        duration: BookingText.duration_label(assigns),
                        name: get_organizer_name(@organizer_profile, @username_context)
                      )}
                    <% else %>
                      {dgettext("booking", "You're booking a %{duration} meeting",
                        duration: BookingText.duration_label(assigns)
                      )}
                    <% end %>
                  </p>

                  <p class="booking-datetime text-quill-secondary">
                    {LocalizationHelpers.format_booking_datetime(
                      @selected_date,
                      @selected_time,
                      @user_timezone
                    )}
                  </p>

                  <LocationField.location_field
                    :if={BookingLocation.choice_required?(assigns)}
                    location_options={@location_options}
                    selected_location_id={@selected_location_id}
                    video_choices={BookingLocation.video_choices(assigns)}
                    selected_video_id={@selected_video_id}
                    location_phone={@location_phone}
                    location_error={@location_error}
                    phone_required={BookingLocation.phone_required?(assigns)}
                    target={@myself}
                  />

                  <.form
                    :let={f}
                    for={@form}
                    as={:booking}
                    phx-change="validate"
                    phx-submit="submit"
                    phx-target={@myself}
                    data-testid="booking-form"
                    class="space-y-2"
                    id="booking-form"
                    {SecurityFields.recaptcha_form_attrs("booking_form", "booking")}
                  >
                    <SecurityFields.honeypot_field id_prefix="booking" param_root="booking" />

                    <div class="booking-inline-fields">
                      <.input
                        field={f[:name]}
                        label={dgettext("booking", "Your Name")}
                        placeholder={dgettext("booking", "John Doe")}
                        errors={FormValidationHelpers.field_errors(@validation_errors, :name)}
                        required
                        phx-debounce="blur"
                        phx-blur="field_blur"
                        phx-value-field="name"
                        phx-target={@myself}
                      />

                      <.input
                        field={f[:email]}
                        label={dgettext("booking", "Email Address")}
                        type="email"
                        placeholder={dgettext("booking", "john@example.com")}
                        errors={FormValidationHelpers.field_errors(@validation_errors, :email)}
                        required
                        phx-debounce="blur"
                        phx-blur="field_blur"
                        phx-value-field="email"
                        phx-target={@myself}
                      />
                    </div>

                    <.input
                      field={f[:message]}
                      type="textarea"
                      label={dgettext("booking", "Additional Message (Optional)")}
                      placeholder={dgettext("booking", "Let me know what you'd like to discuss...")}
                      errors={FormValidationHelpers.field_errors(@validation_errors, :message)}
                      rows={3}
                      phx-debounce="blur"
                      phx-blur="field_blur"
                      phx-value-field="message"
                      phx-target={@myself}
                    />

                    <SecurityFields.recaptcha_token_field id_prefix="booking" param_root="booking" />
                  </.form>

                  <GuestField.guest_field
                    :if={guests_allowed?(assigns)}
                    guest_emails={@guest_emails}
                    guest_input={@guest_input}
                    guest_error={@guest_error}
                    guests_open={@guests_open}
                    max_guests={@max_guests}
                    target={@myself}
                  />

                  <SecurityFields.recaptcha_notice_block />

                  <ApprovalNotice.block
                    :if={Approval.required?(@meeting_type)}
                    organizer_name={get_organizer_name(@organizer_profile, @username_context)}
                    payment_required={@meeting_type.payment_required}
                    stage={:before}
                  />

                  <div class="booking-actions">
                    <.action_button
                      type="button"
                      phx-click="back_step"
                      phx-target={@myself}
                      data-testid="back-step"
                      variant={:secondary}
                      disabled={@submitting}
                      class="flex-1"
                    >
                      ← {dgettext("booking", "Back")}
                    </.action_button>

                    <.loading_button
                      type="submit"
                      form="booking-form"
                      id="submit-booking-button"
                      loading={@submitting}
                      loading_text={dgettext("booking", "Verifying...")}
                      disabled={!OrganizerHelpers.form_valid?(@form)}
                      data-testid="submit-booking"
                      class="flex-1"
                      title={get_submit_title(@submitting, @form)}
                    >
                      {submit_label(@is_rescheduling, @meeting_type)}
                    </.loading_button>
                  </div>
                </div>
              </.glass_morphism_card>
            </div>
          </div>
        </div>
      </.page_layout>
    </div>
    """
  end

  # Helper functions

  # "Book" is a promise the button cannot keep on a gated meeting type, where
  # pressing it sends a request. Naming the action honestly is the cheapest
  # part of this whole feature and the one a visitor reads last — including
  # on a reschedule, which re-enters the approval gate on a gated type just
  # as a fresh submission does.
  defp submit_label(is_rescheduling, meeting_type) do
    BookingLabels.submit_label(
      is_rescheduling,
      meeting_type,
      dgettext("booking", "Book Meeting")
    )
  end

  defp guests_allowed?(assigns), do: GuestBooking.guests_allowed?(assigns)

  defp get_organizer_name(organizer_profile, username_context) do
    BookingLabels.organizer_display_name(organizer_profile, username_context)
  end

  defp get_submit_title(submitting, form) do
    cond do
      submitting ->
        dgettext("booking", "Verifying slot availability and creating your meeting...")

      !OrganizerHelpers.form_valid?(form) ->
        dgettext("booking", "Please fill in all required fields")

      true ->
        dgettext("booking", "Click to schedule your meeting")
    end
  end
end
