defmodule Tymeslot.Bookings.Activation do
  @moduledoc """
  Turning a confirmed meeting into a booking the world knows about.

  Two paths arrive at the same point. A booking on an ordinary meeting type is
  confirmed the moment it is created; a booking on a meeting type requiring
  manual approval is confirmed later, when the host says yes. From that point
  on the work is identical: create the video room if the meeting has a
  provider, then send the confirmation emails and fan out to webhooks,
  Telegram and Slack.

  It lives in its own module so the two paths cannot drift. The ordering
  matters and is easy to get wrong from a second call site: the video room is
  created *before* the emails so the join link is in the confirmation the
  attendee receives, rather than arriving in a later correction. Where a
  provider is configured, that means handing both steps to
  `Tymeslot.Workers.VideoRoomWorker`, which sends the emails itself once the
  room exists — and falls back to sending them without a link if the provider
  is unreachable, so a broken video integration never costs the attendee their
  confirmation.

  A booking created inside a transaction (`Tymeslot.Bookings.Create`,
  `Tymeslot.Bookings.CreateAdHoc`) takes the work in two halves: the room job,
  emails and reminders in the transaction (`activate_in_transaction/2`), and
  the webhook, Telegram and Slack fan-out after it commits (`after_commit/1`).
  A booking confirmed after the fact (approval, payment) takes both at once
  (`activate/2`).
  """

  require Logger

  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Integrations.Video
  alias Tymeslot.Integrations.Video.ProviderConfig, as: VideoProviderConfig
  alias Tymeslot.Meetings.MeetingDeliveryQueries
  alias Tymeslot.Meetings.MeetingSchema, as: Meeting
  alias Tymeslot.Notifications.Events
  alias Tymeslot.Workers.VideoRoomWorker

  # Providers whose rooms Tymeslot creates through an API call, and which
  # therefore need the video job to run before the confirmation email is
  # composed. This is every provider `Video` knows about except `:none` (no
  # integration configured, so there is nothing to create), derived at
  # compile time from `ProviderConfig.known_providers/0` rather than
  # `ProviderConfig.all_providers/0`, because the latter is toggle-filtered:
  # an integration a host already connected before its provider was disabled
  # must still get its room created, not silently skip straight to
  # `notify/1`. Deriving it, instead of restating the provider list by hand,
  # is what keeps a newly registered provider from being missed here the way
  # kMeet and Jitsi once were; the assertion below is a second line of
  # defence against `known_providers/0` ever growing the `:none` sentinel
  # into this list.
  @api_created_providers VideoProviderConfig.known_providers()

  if :none in @api_created_providers do
    raise "ProviderConfig.known_providers/0 must never include :none: it is the " <>
            "sentinel for \"no video integration\", not a provider whose room " <>
            "Activation should hand to VideoRoomWorker"
  end

  @doc """
  Runs the side effects a newly created or newly confirmed meeting needs,
  for a meeting already committed (approval, payment confirmation).

  A meeting still awaiting the host's approval takes the request fan-out; any
  other status takes the confirmation one.

  With `with_video_room: true` the caller asserts the booking flow wants a
  room whenever the meeting has an integration; without it, the provider is
  auto-detected and only the API-backed ones defer the emails.

  Always returns `:ok`. Every failure here is recoverable and separately
  retried — the meeting itself is already committed, and refusing to return
  success would only invite callers to roll back a booking that exists.
  """
  @spec activate(Meeting.t(), keyword()) :: :ok
  def activate(meeting, opts \\ []) do
    meeting
    |> activate_in_transaction(opts)
    |> after_commit()
  end

  @doc """
  `activate/2` for a booking being created inside a transaction, in two
  halves.

  This half runs in the transaction: the video room job, the emails and the
  reminders, all of them jobs written with the meeting, so a booking that
  loses its slot and rolls back leaves none of them behind. It returns the
  integration fan-out (webhooks, Telegram, Slack) still owed, which the
  caller hands to `after_commit/1` once the transaction has committed, and
  drops if it rolls back. The fan-out stays out of the transaction because a
  database error inside one of those best-effort dispatchers, even rescued,
  would leave the transaction unable to commit and lose the booking.
  """
  @spec activate_in_transaction(Meeting.t(), keyword()) :: Events.pending()
  def activate_in_transaction(meeting, opts \\ [])

  # A booking still held for the host to approve is not a booking anyone has
  # agreed to, so none of the confirmation work runs. Branching here rather
  # than at each call site means no future caller can accidentally send a
  # confirmation for a meeting the host has not accepted;
  # `Tymeslot.Meetings.Approval` calls back in once it has confirmed.
  #
  # The request still has to reach people — the invitee needs telling their
  # booking is not final, and the host cannot approve what they never heard
  # about — so it takes the request fan-out instead.
  def activate_in_transaction(%Meeting{status: "awaiting_approval"} = meeting, _opts) do
    {result, pending} = Events.meeting_requested_deferred(meeting)

    with {:error, reason} <- result do
      Logger.error("Failed to schedule booking request emails",
        meeting_id: meeting.id,
        error: LogFormat.reason(reason)
      )
    end

    pending
  end

  def activate_in_transaction(%Meeting{} = meeting, opts) do
    if wants_video_room?(meeting, opts) do
      schedule_video_room_with_announcement(meeting)
    else
      notify(meeting)
    end
  end

  @doc """
  The second half of `activate_in_transaction/2`: the integration fan-out it
  returned, run once the booking has committed. Always returns `:ok`; a
  failing channel is logged and reported, and the booking stands.

  Raises when called inside a transaction. A caller that opens one around a
  booking path (as `Tymeslot.Polls.Confirm` does around
  `Tymeslot.Bookings.CreateAdHoc`) has to take the pending fan-out back and
  run it after its own commit; dispatching inside would put the outer
  transaction at the mercy of every best-effort channel. The raise makes
  such a caller fail on its first test rather than lose a booking in
  production.
  """
  @spec after_commit(Events.pending()) :: :ok
  def after_commit(pending) do
    if MeetingDeliveryQueries.in_transaction?() do
      raise ArgumentError,
            "Activation.after_commit/1 called inside a transaction: return the " <>
              "pending fan-out to the caller that opened it and dispatch after its commit"
    end

    Events.dispatch_deferred(pending)
  end

  @doc """
  True when the meeting's video provider creates its room through an API, so
  the confirmation emails are worth holding until the join link exists.

  Public because the group-booking path
  (`Tymeslot.Bookings.SeatEffects`) faces the same question for the first
  seat on a slot, and must not answer it from a second copy of
  `@api_created_providers`.
  """
  @spec api_created_video_room?(Meeting.t()) :: boolean()
  def api_created_video_room?(%Meeting{} = meeting) do
    match?({:ok, provider} when provider in @api_created_providers, video_provider_for(meeting))
  end

  defp wants_video_room?(meeting, opts) do
    if Keyword.get(opts, :with_video_room, false) do
      not is_nil(meeting.video_integration_id)
    else
      api_created_video_room?(meeting)
    end
  end

  # The room job announces the booking itself once it runs, after commit, so
  # nothing is owed from here.
  defp schedule_video_room_with_announcement(meeting) do
    case VideoRoomWorker.schedule_video_room_creation_with_announcement(meeting.id) do
      :ok -> []
      {:error, _reason} -> notify(meeting)
    end
  end

  defp notify(meeting) do
    {result, pending} = Events.meeting_created_deferred(meeting)

    with {:error, reason} <- result do
      Logger.error("Failed to schedule confirmation emails for meeting",
        meeting_id: meeting.id,
        error: LogFormat.reason(reason)
      )
    end

    pending
  end

  defp video_provider_for(%Meeting{video_integration_id: nil}), do: {:error, :not_found}

  defp video_provider_for(%Meeting{} = meeting) do
    with {:ok, integration} <-
           Video.fetch_integration_for_user(
             meeting.video_integration_id,
             meeting.organizer_user_id
           ) do
      {:ok, parse_provider(integration, meeting)}
    end
  end

  defp parse_provider(integration, meeting) do
    case VideoProviderConfig.parse_known(integration.provider) do
      {:ok, provider} ->
        provider

      {:error, :unknown} ->
        Logger.warning("Video integration has an unrecognised provider",
          video_integration_id: meeting.video_integration_id,
          provider: integration.provider
        )

        :none
    end
  end
end
