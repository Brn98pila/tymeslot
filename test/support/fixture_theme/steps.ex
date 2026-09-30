defmodule TymeslotWeb.Test.FixtureTheme.Scheduling.OverviewStep do
  @moduledoc """
  The fixture theme's overview: the organiser's name, headline and bio (the shared
  `ProfileIntro`), one button per meeting type, and a button sending the theme's own `theme:ping` event.
  """
  use TymeslotWeb, :live_component

  alias Tymeslot.MeetingTypes
  alias Tymeslot.Profiles
  alias TymeslotWeb.Themes.Shared.Components.ProfileIntro
  alias TymeslotWeb.Themes.Shared.StepEvents

  @impl Phoenix.LiveComponent
  defdelegate update(assigns, socket), to: StepEvents

  @impl Phoenix.LiveComponent
  defdelegate handle_event(event, params, socket), to: StepEvents

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <section class="booker-card" data-testid="fixture-overview">
      <h1>{Profiles.display_name(@organizer_profile)}</h1>
      <ProfileIntro.headline profile={@organizer_profile} />
      <ProfileIntro.bio profile={@organizer_profile} />
      <img
        :if={@theme_tokens && @theme_tokens.media[:emblem]}
        src={@theme_tokens.media[:emblem]}
        alt=""
        data-testid="fixture-emblem"
      />
      <button
        :for={meeting_type <- @meeting_types}
        type="button"
        phx-click="select_duration"
        phx-value-duration={MeetingTypes.effective_slug(meeting_type)}
        phx-target={@myself}
        data-testid="duration-option"
        aria-pressed={to_string(@selected_duration == MeetingTypes.effective_slug(meeting_type))}
      >
        {meeting_type.name}
      </button>
      <button
        type="button"
        phx-click="next_step"
        phx-target={@myself}
        data-testid="next-step"
        disabled={is_nil(@selected_duration)}
      >
        Next
      </button>
      <button type="button" phx-click="theme:ping" phx-target={@myself} data-testid="fixture-ping">
        Ping
      </button>
      <p :if={assigns[:fixture_pinged]} data-testid="fixture-pinged">Pinged</p>
    </section>
    """
  end
end

defmodule TymeslotWeb.Test.FixtureTheme.Scheduling.ScheduleStep do
  @moduledoc "The fixture theme's schedule step: a marker and the way back."
  use TymeslotWeb, :live_component

  alias TymeslotWeb.Themes.Shared.StepEvents

  @impl Phoenix.LiveComponent
  defdelegate update(assigns, socket), to: StepEvents

  @impl Phoenix.LiveComponent
  defdelegate handle_event(event, params, socket), to: StepEvents

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <section class="booker-card" data-testid="fixture-schedule">
      <button type="button" phx-click="back_step" phx-target={@myself} data-testid="back-step">
        Back
      </button>
    </section>
    """
  end
end

defmodule TymeslotWeb.Test.FixtureTheme.Scheduling.QuestionsStep do
  @moduledoc "The fixture theme's custom-questions step: a marker only."
  use TymeslotWeb, :live_component

  alias TymeslotWeb.Themes.Shared.CustomQuestions.Events
  alias TymeslotWeb.Themes.Shared.StepEvents

  @impl Phoenix.LiveComponent
  defdelegate update(assigns, socket), to: StepEvents

  @impl Phoenix.LiveComponent
  defdelegate handle_event(event, params, socket), to: Events

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <section class="booker-card" data-testid="fixture-questions"></section>
    """
  end
end

defmodule TymeslotWeb.Test.FixtureTheme.Scheduling.BookingStep do
  @moduledoc "The fixture theme's booking step: a marker and the way back."
  use TymeslotWeb, :live_component

  alias TymeslotWeb.Themes.Shared.StepEvents

  @impl Phoenix.LiveComponent
  defdelegate update(assigns, socket), to: StepEvents

  @impl Phoenix.LiveComponent
  defdelegate handle_event(event, params, socket), to: StepEvents

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <section class="booker-card" data-testid="fixture-booking">
      <button type="button" phx-click="back_step" phx-target={@myself}>Back</button>
    </section>
    """
  end
end

defmodule TymeslotWeb.Test.FixtureTheme.Scheduling.ConfirmationStep do
  @moduledoc "The fixture theme's confirmation step: a marker and a fresh start."
  use TymeslotWeb, :live_component

  alias TymeslotWeb.Themes.Shared.StepEvents

  @impl Phoenix.LiveComponent
  defdelegate update(assigns, socket), to: StepEvents

  @impl Phoenix.LiveComponent
  defdelegate handle_event(event, params, socket), to: StepEvents

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <section class="booker-card" data-testid="fixture-confirmation">
      <button type="button" phx-click="schedule_another" phx-target={@myself}>Again</button>
    </section>
    """
  end
end
