defmodule TymeslotWeb.Test.JourneyFixtures.Moments.Intro do
  @moduledoc """
  Fixture Scroll's masthead: the organiser's name and the summary bar of what
  the visitor has chosen. It collects nothing, so it is on the page from the
  start.
  """
  use TymeslotWeb, :live_component

  alias Tymeslot.Profiles
  alias TymeslotWeb.Themes.Shared.Blocks.SummaryBar
  alias TymeslotWeb.Themes.Shared.StepEvents

  @impl Phoenix.LiveComponent
  defdelegate update(assigns, socket), to: StepEvents

  @impl Phoenix.LiveComponent
  defdelegate handle_event(event, params, socket), to: StepEvents

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <section
      id={"#{@moment}-step"}
      class="booker-card"
      data-moment={@moment}
      data-moment-state={@moment_state}
    >
      <h1>{Profiles.display_name(@organizer_profile)}</h1>
      <SummaryBar.summary_bar
        journey={@journey}
        meeting_type={@meeting_type}
        selected_date={@selected_date}
        selected_time={@selected_time}
        user_timezone={@user_timezone}
      />
    </section>
    """
  end
end

defmodule TymeslotWeb.Test.JourneyFixtures.Moments.Offer do
  @moduledoc """
  The journey fixtures' meeting-type moment: a button per meeting type for the
  meeting type fact, with the approval pill on a type the organiser must
  accept. Once answered, a transcript shows the answer and, where it may be
  changed, an Edit control instead. A meeting type a direct or private link
  chose may not be changed (`Markup.revisitable?/1`): the moment then names
  the chosen type alone, never the organiser's public list beside it. The
  chosen type keeps its approval pill, so a visitor whose type was chosen for
  them (a defaulted only type) still learns it needs approval. A transcript
  opens with the organiser's name, as the first line of the conversation.
  """
  use TymeslotWeb, :live_component

  alias Tymeslot.Meetings.Approval
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Profiles
  alias TymeslotWeb.Test.JourneyFixtures.Markup
  alias TymeslotWeb.Themes.Shared.Components.ApprovalNotice
  alias TymeslotWeb.Themes.Shared.Journey.Components, as: JourneyComponents
  alias TymeslotWeb.Themes.Shared.StepEvents

  @impl Phoenix.LiveComponent
  defdelegate update(assigns, socket), to: StepEvents

  @impl Phoenix.LiveComponent
  defdelegate handle_event(event, params, socket), to: StepEvents

  @impl Phoenix.LiveComponent
  def render(assigns) do
    done = assigns.moment_state == :done

    assigns
    |> assign(
      transcript: Markup.transcript?(assigns),
      answered: Markup.transcript?(assigns) and done,
      locked: done and not Markup.revisitable?(assigns),
      editable: Markup.revisitable?(assigns)
    )
    |> Markup.moment_root(&body/1)
  end

  defp body(assigns) do
    ~H"""
    <p :if={@transcript} data-testid="journey-fixture-host">
      {Profiles.display_name(@organizer_profile)}
    </p>
    <%= cond do %>
      <% @answered -> %>
        <p data-testid="journey-fixture-answer">
          {@meeting_type && @meeting_type.name}
          <ApprovalNotice.pill :if={Approval.required?(@meeting_type)} />
        </p>
        <button
          :if={@editable}
          type="button"
          phx-click="navigate_to_step"
          phx-value-step={@moment}
          data-intent="edit"
        >
          Change meeting type
        </button>
      <% @locked -> %>
        <p data-testid="journey-fixture-answer">
          {@meeting_type && @meeting_type.name}
          <ApprovalNotice.pill :if={Approval.required?(@meeting_type)} />
        </p>
      <% true -> %>
        <JourneyComponents.moment_heading
          moment={@moment}
          moment_state={@moment_state}
          focus={assigns[:journey_focus]}
        >
          What would you like to book?
        </JourneyComponents.moment_heading>
        <button
          :for={meeting_type <- @meeting_types}
          type="button"
          data-testid="duration-option"
          data-fact="meeting_type"
          data-value={MeetingTypes.effective_slug(meeting_type)}
          phx-click="select_duration"
          phx-value-duration={MeetingTypes.effective_slug(meeting_type)}
          phx-target={@myself}
          aria-pressed={to_string(@selected_duration == MeetingTypes.effective_slug(meeting_type))}
        >
          {meeting_type.name}
          <ApprovalNotice.pill :if={Approval.required?(meeting_type)} />
        </button>
    <% end %>
    """
  end
end

defmodule TymeslotWeb.Test.JourneyFixtures.Moments.Ask do
  @moduledoc """
  The journey fixtures' questions moment: the meeting type's questions one at
  a time (the shared questions engine and inputs, which carry the markup
  contract's `data-fact="answer"`), with Back and Continue while it is the
  current moment. The answers are known once confirmed with Continue, so the
  moment stays current while the visitor answers. Once answered it says so
  and offers no control but, on a transcript, Edit: a page that keeps its
  moments on screen must not leave a second way on behind it.
  """
  use TymeslotWeb, :live_component

  alias TymeslotWeb.Test.JourneyFixtures.Markup
  alias TymeslotWeb.Themes.Shared.CustomQuestions.Events
  alias TymeslotWeb.Themes.Shared.CustomQuestions.Inputs.Renderer, as: InputRenderer
  alias TymeslotWeb.Themes.Shared.Journey.Components, as: JourneyComponents
  alias TymeslotWeb.Themes.Shared.StepEvents

  @impl Phoenix.LiveComponent
  defdelegate update(assigns, socket), to: StepEvents

  @impl Phoenix.LiveComponent
  defdelegate handle_event(event, params, socket), to: Events

  @impl Phoenix.LiveComponent
  def render(assigns) do
    assigns =
      assign(assigns,
        answered: assigns.moment_state == :done,
        transcript: Markup.transcript?(assigns)
      )

    # The current question is read only while there is one to ask.
    assigns = if assigns.answered, do: assigns, else: Events.assign_render_state(assigns)

    Markup.moment_root(assigns, &body/1)
  end

  defp body(assigns) do
    ~H"""
    <%= if @answered do %>
      <p data-testid="journey-fixture-answers">Questions answered</p>
      <button
        :if={@transcript}
        type="button"
        phx-click="navigate_to_step"
        phx-value-step={@moment}
        data-intent="edit"
      >
        Change answers
      </button>
    <% else %>
      <JourneyComponents.moment_heading
        moment={@moment}
        moment_state={@moment_state}
        focus={assigns[:journey_focus]}
      >
        {@definition["label"]}
      </JourneyComponents.moment_heading>
      <InputRenderer.render definition={@definition} value={@value} myself={@myself} />
      <p :if={@error} class="form-field__error">{@error}</p>
      <button type="button" phx-click="back_step" phx-target={@myself} data-intent="back">
        Back
      </button>
      <button type="button" phx-click="next_step" phx-target={@myself} data-intent="continue">
        Continue
      </button>
    <% end %>
    """
  end
end

defmodule TymeslotWeb.Test.JourneyFixtures.Moments.When do
  @moduledoc """
  Fixture Scroll's slot moment: the month calendar for the day and the slot
  list for the time.
  """
  use TymeslotWeb, :live_component

  alias TymeslotWeb.Themes.Shared.Blocks.MonthCalendar
  alias TymeslotWeb.Themes.Shared.Components.SlotList
  alias TymeslotWeb.Themes.Shared.Journey.Components, as: JourneyComponents
  alias TymeslotWeb.Themes.Shared.StepEvents

  @impl Phoenix.LiveComponent
  defdelegate update(assigns, socket), to: StepEvents

  @impl Phoenix.LiveComponent
  defdelegate handle_event(event, params, socket), to: StepEvents

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <section
      id={"#{@moment}-step"}
      class="booker-card"
      data-moment={@moment}
      data-moment-state={@moment_state}
    >
      <JourneyComponents.moment_heading
        moment={@moment}
        moment_state={@moment_state}
        focus={assigns[:journey_focus]}
      >
        When suits you?
      </JourneyComponents.moment_heading>
      <MonthCalendar.month_calendar
        current_year={@current_year}
        current_month={@current_month}
        user_timezone={@user_timezone}
        selected_date={@selected_date}
        availability_status={@availability_status}
        booking_window_days={assigns[:booking_window_days]}
        organizer_profile={@organizer_profile}
        month_availability_map={@month_availability_map}
        meeting_type={@meeting_type}
        target={@myself}
      />
      <SlotList.slot_list
        selected_date={@selected_date}
        selected_time={@selected_time}
        available_slots={@available_slots}
        loading_slots={@loading_slots}
        calendar_error={@calendar_error}
        slot_interval_minutes={@slot_interval_minutes}
        duration_minutes={@duration_minutes}
        expanded_hour={@expanded_hour}
        target={@myself}
      />
    </section>
    """
  end
end

defmodule TymeslotWeb.Test.JourneyFixtures.Moments.Day do
  @moduledoc """
  Fixture Talk's "which day?" bubble: the next free days as chips. It collects
  nothing, so it is open whenever reached. A fact's event is taken only from
  a moment collecting the fact, so its chips send the day to the times
  moment after it (`#time-step`), which collects the slot and is on screen
  with it. Once a time is chosen it names the day instead.
  """
  use TymeslotWeb, :live_component

  alias TymeslotWeb.Test.JourneyFixtures.Markup
  alias TymeslotWeb.Themes.Shared.Blocks.DayChips
  alias TymeslotWeb.Themes.Shared.Journey.Components, as: JourneyComponents
  alias TymeslotWeb.Themes.Shared.LocalizationHelpers
  alias TymeslotWeb.Themes.Shared.StepEvents

  @impl Phoenix.LiveComponent
  defdelegate update(assigns, socket), to: StepEvents

  @impl Phoenix.LiveComponent
  defdelegate handle_event(event, params, socket), to: StepEvents

  @impl Phoenix.LiveComponent
  def render(assigns), do: Markup.moment_root(assigns, &body/1)

  defp body(assigns) do
    ~H"""
    <%= if @selected_time do %>
      <p data-testid="journey-fixture-day">
        {LocalizationHelpers.format_full_date_label(@selected_date)}
      </p>
    <% else %>
      <JourneyComponents.moment_heading
        moment={@moment}
        moment_state={@moment_state}
        focus={assigns[:journey_focus]}
      >
        Which day suits you?
      </JourneyComponents.moment_heading>
      <DayChips.day_chips
        availability={@month_availability_map}
        availability_status={@availability_status}
        user_timezone={@user_timezone}
        selected_date={@selected_date}
        target="#time-step"
      />
    <% end %>
    """
  end
end

defmodule TymeslotWeb.Test.JourneyFixtures.Moments.Time do
  @moduledoc """
  Fixture Talk's times: the chosen day's times (the shared slot list), and
  once answered the time with an Edit control.
  """
  use TymeslotWeb, :live_component

  alias TymeslotWeb.Test.JourneyFixtures.Markup
  alias TymeslotWeb.Themes.Shared.Components.SlotList
  alias TymeslotWeb.Themes.Shared.Journey.Components, as: JourneyComponents
  alias TymeslotWeb.Themes.Shared.LocalizationHelpers
  alias TymeslotWeb.Themes.Shared.StepEvents

  @impl Phoenix.LiveComponent
  defdelegate update(assigns, socket), to: StepEvents

  @impl Phoenix.LiveComponent
  defdelegate handle_event(event, params, socket), to: StepEvents

  @impl Phoenix.LiveComponent
  def render(assigns), do: Markup.moment_root(assigns, &body/1)

  defp body(assigns) do
    ~H"""
    <%= if @moment_state == :done do %>
      <p data-testid="journey-fixture-answer">
        {LocalizationHelpers.format_booking_datetime(@selected_date, @selected_time, @user_timezone)}
      </p>
      <button type="button" phx-click="navigate_to_step" phx-value-step={@moment} data-intent="edit">
        Change time
      </button>
    <% else %>
      <JourneyComponents.moment_heading
        moment={@moment}
        moment_state={@moment_state}
        focus={assigns[:journey_focus]}
      >
        Which time?
      </JourneyComponents.moment_heading>
      <SlotList.slot_list
        selected_date={@selected_date}
        selected_time={@selected_time}
        available_slots={@available_slots}
        loading_slots={@loading_slots}
        calendar_error={@calendar_error}
        slot_interval_minutes={@slot_interval_minutes}
        duration_minutes={@duration_minutes}
        expanded_hour={@expanded_hour}
        target={@myself}
      />
    <% end %>
    """
  end
end

defmodule TymeslotWeb.Test.JourneyFixtures.Moments.You do
  @moduledoc """
  The journey fixtures' attendee moment: the day and time chosen, the
  location choice when the meeting type offers several, the shared booking
  form with the guest field, the approval notice for a type the organiser
  must accept, the submit control (named as every theme names it) and, on a
  paged journey, the way back.
  """
  use TymeslotWeb, :live_component

  alias Tymeslot.Meetings.Approval
  alias Tymeslot.Profiles
  alias TymeslotWeb.Test.JourneyFixtures.Markup
  alias TymeslotWeb.Themes.Shared.BookingLabels
  alias TymeslotWeb.Themes.Shared.BookingLocation
  alias TymeslotWeb.Themes.Shared.Components.ApprovalNotice
  alias TymeslotWeb.Themes.Shared.Components.BookingForm
  alias TymeslotWeb.Themes.Shared.Components.GuestField
  alias TymeslotWeb.Themes.Shared.Components.LocationField
  alias TymeslotWeb.Themes.Shared.GuestBooking
  alias TymeslotWeb.Themes.Shared.Journey.Components, as: JourneyComponents
  alias TymeslotWeb.Themes.Shared.LocalizationHelpers
  alias TymeslotWeb.Themes.Shared.StepEvents

  @impl Phoenix.LiveComponent
  defdelegate update(assigns, socket), to: StepEvents

  @impl Phoenix.LiveComponent
  defdelegate handle_event(event, params, socket), to: StepEvents

  @impl Phoenix.LiveComponent
  def render(assigns) do
    assigns
    |> assign(:paged, Markup.paged?(assigns))
    |> Markup.moment_root(&body/1)
  end

  defp body(assigns) do
    ~H"""
    <JourneyComponents.moment_heading
      moment={@moment}
      moment_state={@moment_state}
      focus={assigns[:journey_focus]}
    >
      Your details
    </JourneyComponents.moment_heading>
    <p data-testid="journey-fixture-slot">
      {LocalizationHelpers.format_booking_datetime(@selected_date, @selected_time, @user_timezone)}
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
    <BookingForm.booking_form form={@form} validation_errors={@validation_errors} target={@myself}>
      <GuestField.guest_field
        :if={GuestBooking.guests_allowed?(assigns)}
        guest_emails={@guest_emails}
        guest_input={@guest_input}
        guest_error={@guest_error}
        guests_open={@guests_open}
        max_guests={@max_guests}
        target={@myself}
      />
    </BookingForm.booking_form>
    <ApprovalNotice.block
      :if={Approval.required?(@meeting_type)}
      organizer_name={Profiles.display_name(@organizer_profile)}
      payment_required={@meeting_type.payment_required}
      stage={:before}
    />
    <button type="submit" form="booking-form" data-intent="submit" data-testid="submit-booking">
      {BookingLabels.submit_label(assigns[:is_rescheduling] || false, @meeting_type, "Book")}
    </button>
    <button
      :if={@paged}
      type="button"
      phx-click="back_step"
      phx-target={@myself}
      data-intent="back"
    >
      Back
    </button>
    """
  end
end

defmodule TymeslotWeb.Test.JourneyFixtures.Moments.Confirmation do
  @moduledoc """
  The journey fixtures' confirmation outcome: what every theme tells the
  booker (whether the booking is held for approval or confirmed, the address
  the details went to, the meeting's length, and the approval notice while it
  is held), unstyled, and a fresh start.
  """
  use TymeslotWeb, :live_component

  alias Tymeslot.Availability.Offer
  alias Tymeslot.Profiles
  alias TymeslotWeb.Themes.Shared.ApprovalDisplay
  alias TymeslotWeb.Themes.Shared.Components.ApprovalNotice
  alias TymeslotWeb.Themes.Shared.ConfirmationText
  alias TymeslotWeb.Themes.Shared.StepEvents

  @impl Phoenix.LiveComponent
  defdelegate update(assigns, socket), to: StepEvents

  @impl Phoenix.LiveComponent
  defdelegate handle_event(event, params, socket), to: StepEvents

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <section class="booker-card" data-testid="journey-fixture-confirmation">
      <h2 data-testid="confirmation-heading">{headline(assigns)}</h2>
      <p data-testid="journey-fixture-confirmation-email">{@email}</p>
      <p data-testid="journey-fixture-confirmation-length">
        {Offer.duration_minutes(@meeting_type, @duration)} min
      </p>
      <ApprovalNotice.block
        :if={ApprovalDisplay.awaiting_approval?(assigns)}
        organizer_name={Profiles.display_name(@organizer_profile)}
        stage={:after}
      />
      <button type="button" phx-click="schedule_another" phx-target={@myself} data-intent="restart">
        Book another
      </button>
    </section>
    """
  end

  # Which status applies is decided in `ConfirmationText`, as on every theme;
  # the words are the fixture's own, the held one as the shipped themes put it.
  defp headline(assigns) do
    case ConfirmationText.status(assigns) do
      :held -> "Request sent!"
      :rescheduled -> "Rescheduled"
      :confirmed -> "Booked"
    end
  end
end
