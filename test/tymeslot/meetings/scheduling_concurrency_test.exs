defmodule Tymeslot.Meetings.SchedulingConcurrencyTest do
  @moduledoc """
  Races between solo bookings of one organiser, on real connections, staged
  by `Tymeslot.Test.RaceConductor` (see its moduledoc for why the module is
  synchronous and why `on_exit` deletes what it committed).

  Each contender parks right after inserting its meeting, inside the booking
  transaction. With the organiser's schedule lock in place one contender
  parks at a time and the other waits for the lock, then sees the first
  meeting once it commits; without it both read an empty window, park, and
  both commit.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :meetings
  @moduletag :bookings
  @moduletag :integration

  import Ecto.Query, only: [from: 2]
  import Tymeslot.Factory
  import Tymeslot.Test.RaceConductor, only: [race: 1, unboxed: 1]

  alias Ecto.UUID
  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.Scheduling
  alias Tymeslot.Repo
  alias Tymeslot.Test.RaceConductor

  setup do
    user =
      unboxed(fn ->
        user = insert(:user)
        insert(:profile, user: user)
        user
      end)

    on_exit(fn ->
      unboxed(fn ->
        Repo.delete_all(from(m in MeetingSchema, where: m.organizer_user_id == ^user.id))
        Repo.delete_all(from(u in UserSchema, where: u.id == ^user.id))
      end)
    end)

    RaceConductor.attach_parking()

    %{user: user, start: tomorrow_at(10)}
  end

  test "two bookings of overlapping, different windows: exactly one commits", ctx do
    results =
      race([
        fn hold -> book(ctx.user, ctx.start, 60, hold) end,
        fn hold -> book(ctx.user, DateTime.add(ctx.start, 30, :minute), 60, hold) end
      ])

    assert Enum.count(results, &match?({:ok, %MeetingSchema{}}, &1)) == 1
    assert Enum.count(results, &match?({:error, :time_conflict}, &1)) == 1
    assert committed_meetings(ctx.user) == 1
  end

  test "two bookings of the same start: the loser gets a time conflict", ctx do
    results =
      race([
        fn hold -> book(ctx.user, ctx.start, 30, hold) end,
        fn hold -> book(ctx.user, ctx.start, 30, hold) end
      ])

    assert Enum.count(results, &match?({:ok, %MeetingSchema{}}, &1)) == 1
    assert Enum.count(results, &match?({:error, :time_conflict}, &1)) == 1
    assert committed_meetings(ctx.user) == 1
  end

  defp book(user, start_time, minutes, hold) do
    RaceConductor.arm(hold, RaceConductor.insert_into("meetings"))

    Scheduling.create_meeting_with_conflict_check(%{
      uid: UUID.generate(),
      title: "Race",
      start_time: start_time,
      end_time: DateTime.add(start_time, minutes, :minute),
      duration: minutes,
      status: "confirmed",
      organizer_user_id: user.id,
      organizer_name: "Organiser",
      organizer_email: "organiser-#{user.id}@example.com",
      attendee_name: "Attendee",
      attendee_email: "attendee-#{System.unique_integer([:positive])}@example.com",
      attendee_timezone: "Etc/UTC",
      attendee_locale: "en"
    })
  end

  defp committed_meetings(user) do
    unboxed(fn ->
      Repo.aggregate(from(m in MeetingSchema, where: m.organizer_user_id == ^user.id), :count)
    end)
  end

  defp tomorrow_at(hour) do
    DateTime.utc_now()
    |> DateTime.add(1, :day)
    |> then(&%{&1 | hour: hour, minute: 0, second: 0, microsecond: {0, 0}})
  end
end
