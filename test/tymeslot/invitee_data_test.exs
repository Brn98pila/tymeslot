defmodule Tymeslot.InviteeDataTest do
  use Tymeslot.DataCase, async: true

  @moduletag :meetings
  @moduletag :integration

  import Tymeslot.Factory

  alias Tymeslot.InviteeData
  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.Meetings.GuestQueries
  alias Tymeslot.Meetings.GuestSchema
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.ParticipantSchema
  alias Tymeslot.Polls.PollParticipantSchema
  alias Tymeslot.Polls.PollVoteSchema
  alias Tymeslot.Webhooks.WebhookDeliverySchema

  @email "ada@example.com"

  defp ended(days_ago) do
    end_time = DateTime.utc_now() |> DateTime.add(-days_ago, :day) |> DateTime.truncate(:second)
    [start_time: DateTime.add(end_time, -60, :minute), end_time: end_time]
  end

  defp past_meeting(attrs) do
    insert(:meeting, Keyword.merge(ended(10) ++ [status: "completed"], attrs))
  end

  defp add_guest(meeting, email, attrs \\ %{}) do
    {:ok, guest} =
      GuestQueries.insert_guest(
        Map.merge(%{meeting_id: meeting.id, email: email, name: "A Guest"}, attrs)
      )

    guest
  end

  defp poll_with_slot_ended(days_ago, host) do
    poll = insert(:poll, user: host)
    slot = insert(:poll_time_slot, [poll: poll] ++ ended(days_ago))
    {poll, slot}
  end

  describe "erase/1" do
    setup do
      host = insert(:user)

      booked =
        past_meeting(
          organizer_user: host,
          attendee_name: "Ada Lovelace",
          attendee_email: "Ada@Example.com",
          attendee_phone: "+41 79 000 00 00",
          attendee_message: "See you there",
          location: "Phone call (+41 79 000 00 00)",
          title: "Intro call with Ada Lovelace",
          summary: "Intro call with Ada Lovelace",
          meeting_type: "Intro call",
          custom_field_answers: %{"company_size" => "12"},
          visitor_hash: "abc123",
          cancellation_reason: "Something came up"
        )

      group = insert(:group_meeting, [organizer_user: host, status: "completed"] ++ ended(10))
      seat = insert(:participant, meeting: group, email: @email, name: "Ada", phone: "123")
      other_seat = insert(:participant, meeting: group, email: "bob@example.com", name: "Bob")

      invited = past_meeting(organizer_user: host)
      guest = add_guest(invited, @email)
      guest_of_booker = add_guest(booked, "carol@example.com")

      {poll, slot} = poll_with_slot_ended(10, host)
      voter = insert(:poll_participant, poll: poll, email: @email, name: "Ada")
      vote = insert(:poll_vote, participant: voter, time_slot: slot)

      payment =
        insert(:booking_payment,
          host_user_id: host.id,
          meeting_id: booked.id,
          attendee_email: @email
        )

      delivery = insert(:webhook_delivery, meeting_id: booked.id)

      %{
        booked: booked,
        seat: seat,
        other_seat: other_seat,
        guest: guest,
        guest_of_booker: guest_of_booker,
        voter: voter,
        vote: vote,
        payment: payment,
        delivery: delivery
      }
    end

    test "clears the person's details everywhere they gave them, keeping the rows", ctx do
      assert {:ok, counts} = InviteeData.erase("  ADA@example.com ")

      assert counts == %{
               meetings: 1,
               participants: 1,
               guests: 1,
               poll_participants: 1,
               booking_payments: 1,
               deliveries: 1
             }

      meeting = Repo.get!(MeetingSchema, ctx.booked.id)

      assert %{
               attendee_name: nil,
               attendee_email: nil,
               attendee_phone: nil,
               attendee_message: nil,
               location: nil,
               title: "Intro call",
               summary: "Intro call",
               custom_field_answers: %{},
               visitor_hash: nil,
               cancellation_reason: nil,
               status: "completed",
               meeting_type: "Intro call"
             } = meeting

      seat = Repo.get!(ParticipantSchema, ctx.seat.id)
      assert %{name: "", phone: nil, management_token_hash: nil} = seat
      assert seat.email == "erased-#{seat.id}@erased.invalid"

      guest = Repo.get!(GuestSchema, ctx.guest.id)
      assert %{name: nil, rsvp_token_hash: nil} = guest
      assert guest.email == "erased-#{guest.id}@erased.invalid"

      voter = Repo.get!(PollParticipantSchema, ctx.voter.id)
      assert %{name: "", token_hash: nil} = voter
      assert Repo.get(PollVoteSchema, ctx.vote.id)

      payment = Repo.get!(BookingPaymentSchema, ctx.payment.id)
      assert %{attendee_email: nil, attendee_name: nil, amount_cents: 5000} = payment

      refute Repo.get(WebhookDeliverySchema, ctx.delivery.id)
    end

    test "leaves other people untouched, including the guests the person invited", ctx do
      assert {:ok, _counts} = InviteeData.erase(@email)

      assert %{name: "Bob", email: "bob@example.com"} =
               Repo.get!(ParticipantSchema, ctx.other_seat.id)

      assert %{email: "carol@example.com"} = Repo.get!(GuestSchema, ctx.guest_of_booker.id)
    end

    test "refuses while the person still has an upcoming booking, and changes nothing", ctx do
      upcoming = insert(:future_meeting, attendee_email: @email)

      assert {:error, {:upcoming_meetings, [uid]}} = InviteeData.erase(@email)
      assert uid == upcoming.uid

      assert %{attendee_name: "Ada Lovelace"} = Repo.get!(MeetingSchema, ctx.booked.id)
      assert %{email: @email} = Repo.get!(PollParticipantSchema, ctx.voter.id)
    end

    test "refuses for an upcoming group seat or guest invitation too" do
      group = insert(:group_meeting, ended(-7))
      insert(:participant, meeting: group, email: "seat@example.com")
      assert {:error, {:upcoming_meetings, [_uid]}} = InviteeData.erase("seat@example.com")

      add_guest(insert(:future_meeting), "guest@example.com")
      assert {:error, {:upcoming_meetings, [_uid]}} = InviteeData.erase("guest@example.com")
    end

    test "erases despite an upcoming booking that was cancelled", ctx do
      insert(:future_meeting, attendee_email: @email, status: "cancelled")

      assert {:ok, %{meetings: 2}} = InviteeData.erase(@email)
      assert %{attendee_email: nil} = Repo.get!(MeetingSchema, ctx.booked.id)
    end

    test "keeps a location that does not carry the attendee's phone" do
      meeting =
        past_meeting(attendee_email: "dan@example.com", location: "Room 4", attendee_phone: nil)

      assert {:ok, _counts} = InviteeData.erase("dan@example.com")
      assert %{location: "Room 4"} = Repo.get!(MeetingSchema, meeting.id)
    end

    test "rejects a blank or missing email" do
      assert {:error, :invalid_email} = InviteeData.erase("   ")
      assert {:error, :invalid_email} = InviteeData.erase(nil)
    end
  end

  describe "erase_for_host/2" do
    test "erases only what the person gave that host" do
      host = insert(:user)
      other_host = insert(:user)

      mine = past_meeting(organizer_user: host, attendee_email: @email)
      theirs = past_meeting(organizer_user: other_host, attendee_email: @email)
      {their_poll, _slot} = poll_with_slot_ended(10, other_host)
      their_voter = insert(:poll_participant, poll: their_poll, email: @email)

      assert {:ok, %{meetings: 1, poll_participants: 0}} =
               InviteeData.erase_for_host(host.id, @email)

      assert %{attendee_email: nil} = Repo.get!(MeetingSchema, mine.id)
      assert %{attendee_email: @email} = Repo.get!(MeetingSchema, theirs.id)
      assert %{email: @email} = Repo.get!(PollParticipantSchema, their_voter.id)
    end

    test "is not blocked by the person's upcoming booking with another host" do
      host = insert(:user)
      past_meeting(organizer_user: host, attendee_email: @email)
      insert(:future_meeting, organizer_user: insert(:user), attendee_email: @email)

      assert {:ok, %{meetings: 1}} = InviteeData.erase_for_host(host.id, @email)
    end
  end

  describe "anonymise_expired/1" do
    test "anonymises meetings that ended before the window, with their seats, guests and payments" do
      old =
        past_meeting(
          Keyword.merge(ended(731), attendee_email: "old@example.com", attendee_name: "Old")
        )

      recent = past_meeting(Keyword.merge(ended(700), attendee_email: "recent@example.com"))

      old_guest = add_guest(old, "oldguest@example.com")
      old_group = insert(:group_meeting, ended(800))
      old_seat = insert(:participant, meeting: old_group, email: "oldseat@example.com")
      old_payment = insert(:booking_payment, meeting_id: old.id)

      assert {2, nil} = InviteeData.anonymise_expired(730)

      assert %{attendee_email: nil, attendee_name: nil, invitee_data_erased_at: %DateTime{}} =
               Repo.get!(MeetingSchema, old.id)

      assert %{invitee_data_erased_at: %DateTime{}} = Repo.get!(MeetingSchema, old_group.id)
      assert Repo.get!(GuestSchema, old_guest.id).email =~ "@erased.invalid"
      assert Repo.get!(ParticipantSchema, old_seat.id).email =~ "@erased.invalid"
      assert %{attendee_email: nil} = Repo.get!(BookingPaymentSchema, old_payment.id)

      assert %{attendee_email: "recent@example.com", invitee_data_erased_at: nil} =
               Repo.get!(MeetingSchema, recent.id)
    end

    test "anonymises the participants of polls whose last proposed time ended before the window" do
      host = insert(:user)
      {old_poll, old_slot} = poll_with_slot_ended(731, host)
      old_voter = insert(:poll_participant, poll: old_poll)
      vote = insert(:poll_vote, participant: old_voter, time_slot: old_slot)

      {mixed_poll, _slot} = poll_with_slot_ended(800, host)
      insert(:poll_time_slot, [poll: mixed_poll] ++ ended(10))
      mixed_voter = insert(:poll_participant, poll: mixed_poll)

      assert {1, nil} = InviteeData.anonymise_expired(730)

      assert Repo.get!(PollParticipantSchema, old_voter.id).email =~ "@erased.invalid"
      assert Repo.get(PollVoteSchema, vote.id)
      assert Repo.get!(PollParticipantSchema, mixed_voter.id).email == mixed_voter.email
    end

    test "passes over what it has already anonymised" do
      host = insert(:user)
      past_meeting(ended(731))
      {poll, _slot} = poll_with_slot_ended(731, host)
      insert(:poll_participant, poll: poll)

      assert {2, nil} = InviteeData.anonymise_expired(730)
      assert {0, nil} = InviteeData.anonymise_expired(730)
    end

    test "anonymises nothing for a window that is not a positive number of days" do
      meeting = past_meeting([])

      assert {0, nil} = InviteeData.anonymise_expired(0)
      assert {0, nil} = InviteeData.anonymise_expired(-5)
      assert %{invitee_data_erased_at: nil} = Repo.get!(MeetingSchema, meeting.id)
    end
  end
end
