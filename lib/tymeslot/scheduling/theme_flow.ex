defmodule Tymeslot.Scheduling.ThemeFlow do
  @moduledoc """
  Shared scheduling helpers for theme flows.

  This module keeps domain logic in the core so LiveViews only orchestrate UI state.
  """

  alias Tymeslot.Bookings.Errors
  alias Tymeslot.Bookings.Orchestrator
  alias Tymeslot.Demo
  alias Tymeslot.Meetings
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Scheduling.RescheduleContext
  alias Tymeslot.Security.FieldValidators.EmailValidator
  alias Tymeslot.Security.FieldValidators.NameValidator

  @prefill_validators %{"name" => NameValidator, "email" => EmailValidator}

  @spec resolve_meeting_type_for_duration(pos_integer(), String.t()) :: map() | nil
  def resolve_meeting_type_for_duration(user_id, duration) do
    duration_slug = MeetingTypes.normalize_duration_slug(duration)
    Demo.find_by_duration_string(user_id, duration_slug)
  end

  @spec resolve_meeting_type_for_slug(pos_integer(), String.t()) :: map() | nil
  def resolve_meeting_type_for_slug(user_id, slug) do
    Demo.find_by_slug(user_id, slug)
  end

  @doc """
  The booking a reschedule page is moving, loaded once, with what the page
  starts from (`Tymeslot.Scheduling.RescheduleContext`).

  The lookup is scoped to the organiser, so a uid cannot reveal another
  organiser's attendee, and refuses a booking the rules no longer let move
  with the reason `Tymeslot.Bookings.Orchestrator.get_meeting_for_reschedule/2`
  gives.

  The meeting type is the one the reschedule is already committed to.
  Matching by duration is right while a visitor is still choosing what to
  book, but a reschedule is not a choice: the rules enforced on submit come
  from the original meeting's type, and two types sharing a duration may sit
  on different availability schedules. Resolving by duration could therefore
  offer slots from one schedule and reject the booking against another's. It
  is `nil` when the meeting predates meeting types or its type has since been
  deleted; the caller then falls back to the duration match.
  """
  @spec reschedule_context(String.t(), integer()) ::
          {:ok, RescheduleContext.t()} | {:error, Errors.classified_error()}
  def reschedule_context(meeting_uid, organizer_user_id)
      when is_binary(meeting_uid) and is_integer(organizer_user_id) do
    with {:ok, meeting} <-
           Orchestrator.get_meeting_for_reschedule(meeting_uid, organizer_user_id) do
      {:ok, RescheduleContext.new(meeting, meeting_type_of(meeting, organizer_user_id))}
    end
  end

  defp meeting_type_of(%{meeting_type_id: id}, organizer_user_id) when is_integer(id),
    do: MeetingTypes.get_meeting_type(id, organizer_user_id)

  defp meeting_type_of(_meeting, _organizer_user_id), do: nil

  @doc """
  The meeting type a group participant's seat move is committed to: the type
  of the meeting their live seat is on, provided that meeting is this
  organiser's.

  `nil` for a spent token, a seat on another organiser's meeting (a
  hand-edited username), or a type that has since been deleted, the same
  cases in which `reschedule_context/2` finds no type for a uid.
  """
  @spec resolve_meeting_type_for_seat(String.t() | nil, integer() | nil) :: map() | nil
  def resolve_meeting_type_for_seat(seat_token, organizer_user_id)
      when is_binary(seat_token) and is_integer(organizer_user_id) do
    with {:ok, %{meeting: %{organizer_user_id: ^organizer_user_id, meeting_type_id: id}}}
         when is_integer(id) <- Meetings.fetch_live_seat(seat_token),
         %{} = meeting_type <- MeetingTypes.get_meeting_type(id, organizer_user_id) do
      meeting_type
    else
      _not_resolvable -> nil
    end
  end

  def resolve_meeting_type_for_seat(_seat_token, _organizer_user_id), do: nil

  @doc """
  The location the meeting being rescheduled was booked at, as the picker
  records a choice: the option id, the booker's own number if the option
  asked for one, the video provider the meeting is on, and the saved venue
  it is at. Also the location as the meeting stores it (`location` and
  `address_to_arrange`), which a time-only reschedule keeps and the page
  states.

  `nil` when the page is not moving a booking, which leaves the picker
  opening on the host's first option.
  """
  @spec reschedule_location_choice(RescheduleContext.t() | nil) ::
          RescheduleContext.location_choice() | nil
  def reschedule_location_choice(%RescheduleContext{location_choice: choice}), do: choice
  def reschedule_location_choice(nil), do: nil

  @doc """
  The attendee details a booking link carried in its URL fragment
  (`/:username#name=…&email=…`), reduced to what may seed the booking form.

  The fragment never reaches the server in a request, so the name and email
  stay out of access logs and `Referer` headers; the browser reads it and
  passes it on with the LiveView connection. Only `name` and `email` are kept,
  each trimmed and stripped of null bytes, and only when the booking form's
  own validator accepts it: a value that would fail on submit is left for the
  visitor to type rather than shown already wrong. Anything else (no map, a
  non-string value) yields no prefill.
  """
  @spec attendee_prefill(any()) :: %{optional(String.t()) => String.t()}
  def attendee_prefill(%{} = params) do
    for {field, validator} <- @prefill_validators,
        value = clean_prefill(params[field]),
        validator.validate(value) == :ok,
        into: %{},
        do: {field, value}
  end

  def attendee_prefill(_params), do: %{}

  defp clean_prefill(value) when is_binary(value),
    do: value |> String.replace("\x00", "") |> String.trim()

  defp clean_prefill(_value), do: nil

  @doc """
  The booking form's starting values.

  A reschedule starts from the details of the booking being moved (the
  context's `form_data`). Any other booking starts blank, overlaid with
  `prefill` (see `attendee_prefill/1`); a reschedule ignores it, since the
  attendee is already known.
  """
  @spec build_booking_form_data(RescheduleContext.t() | nil, map()) :: map()
  def build_booking_form_data(context, prefill \\ %{})

  def build_booking_form_data(%RescheduleContext{form_data: form_data}, _prefill), do: form_data

  def build_booking_form_data(nil, prefill), do: Map.merge(default_booking_form_data(), prefill)

  @doc """
  The custom field answers a reschedule carries over from the booking being
  moved, for the definitions the meeting type offers *now*. Nothing when the
  page is not moving a booking.

  The booking stores both the answers and `custom_fields_snapshot`, the
  definitions as the booker saw them. An answer is carried over only where the
  two definitions still match, because a question that has been edited since is
  a different question: the same id may now ask something else, offer different
  options, or expect a different type, and an answer to the old wording would
  be put in the booker's mouth. Such a question is left blank, to be answered
  again.

  A question's `position` is excluded from that comparison: reordering the
  form does not change what any one question asks.

  Answers whose question has been removed are dropped, and questions added
  since simply have nothing to carry over. A note's acknowledgement is never
  carried: it records that the booker actively confirmed the text, and the
  submit stamps the confirmation time afresh, so a pre-ticked card would
  record consent the booker never gave for the moved booking.

  The definitions are passed in rather than read off the context's meeting
  type: when that type has been deleted, the page books against the type it
  fell back to, and those are the questions it asks.
  """
  @spec reschedule_answers(RescheduleContext.t() | nil, [map()]) :: %{String.t() => any()}
  def reschedule_answers(%RescheduleContext{meeting: meeting}, definitions)
      when is_list(definitions) do
    carry_over_answers(
      definitions,
      meeting.custom_fields_snapshot || [],
      meeting.custom_field_answers || %{}
    )
  end

  def reschedule_answers(nil, _definitions), do: %{}

  defp carry_over_answers(definitions, booked_snapshot, booked_answers) do
    booked_by_id = Map.new(booked_snapshot, &{&1["id"], comparable(&1)})

    for %{"type" => type} = definition when type != "note" <- definitions,
        id = definition["id"],
        Map.has_key?(booked_answers, id),
        Map.get(booked_by_id, id) == comparable(definition),
        into: %{},
        do: {id, Map.fetch!(booked_answers, id)}
  end

  defp comparable(definition), do: Map.delete(definition, "position")

  defp default_booking_form_data do
    %{"name" => "", "email" => "", "message" => ""}
  end

  @doc """
  Pre-fills the booking form for a seat reschedule from the participant's
  own data. The token scopes the lookup, so no organizer id is needed and
  no other booker's PII can be pre-filled.
  """
  @spec build_seat_booking_form_data(String.t() | nil) :: %{String.t() => String.t()}
  def build_seat_booking_form_data(nil), do: default_booking_form_data()

  def build_seat_booking_form_data(seat_token) when is_binary(seat_token) do
    case Meetings.get_participant_by_token(seat_token) do
      {:ok, %{cancelled_at: nil} = participant} ->
        %{
          "name" => participant.name,
          "email" => participant.email,
          "message" => participant.message || ""
        }

      _cancelled_or_missing ->
        default_booking_form_data()
    end
  end

  @doc """
  The start of the live seat a seat-management token names: the time the
  participant is moving their spot from. `nil` when the token is spent.

  The token rides in the picker URL as `reschedule_seat_token`, which browser
  history keeps long after the seat has been moved or given up. A dead token
  left in the assigns routes every later submission through the seat-move
  path, where it can only fail, so the booking page checks it once and
  forgets it if it is spent, letting the visitor simply book afresh.
  """
  @spec seat_move_start(String.t() | nil) :: DateTime.t() | nil
  def seat_move_start(seat_token) when is_binary(seat_token) do
    case Meetings.fetch_live_seat(seat_token) do
      {:ok, %{meeting: meeting}} -> meeting.start_time
      {:error, _dead_end} -> nil
    end
  end

  def seat_move_start(_missing), do: nil
end
