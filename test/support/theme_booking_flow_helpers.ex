defmodule Tymeslot.ThemeBookingFlowHelpers do
  @moduledoc """
  The booking walks the shared suites used before `TymeslotWeb.BookingDriver`,
  kept as calls into it while the suites move to the driver itself; removed
  once none calls them. New tests use `BookingDriver` directly.
  """

  alias TymeslotWeb.BookingDriver

  @doc """
  Drives an already-mounted booking view from overview to the outcome,
  booking "quick-chat" for `attendee`; returns the rendered outcome.
  """
  @spec complete_booking_flow(term(), String.t(), String.t(), map()) :: binary()
  def complete_booking_flow(view, _theme_name, _theme_id, attendee),
    do: BookingDriver.book(view, meeting_type: "quick-chat", attendee: attendee)

  @doc """
  As `complete_booking_flow/4`, without waiting for an outcome: for a
  submission expected not to confirm (a preview without a valid owner token).
  """
  @spec fill_and_submit_booking_flow(term(), String.t(), String.t(), map()) :: :ok
  def fill_and_submit_booking_flow(view, _theme_name, _theme_id, attendee) do
    _page =
      BookingDriver.book(view, meeting_type: "quick-chat", attendee: attendee, until: :submitted)

    :ok
  end

  @doc "Drives a mounted booking view from overview to the booking form, without submitting."
  @spec advance_to_booking_form(term(), String.t()) :: :ok
  def advance_to_booking_form(view, _theme_name) do
    _page = BookingDriver.book(view, meeting_type: "quick-chat", until: :attendee)
    :ok
  end

  @doc "Picks the first free time on the schedule step; returns `{iso_date, time}`."
  @spec select_first_slot(term()) :: {String.t(), String.t()}
  def select_first_slot(view), do: BookingDriver.pick_first_slot(view)

  @doc "Returns the next weekday strictly after `start_date`."
  @spec next_business_day(Date.t()) :: Date.t()
  def next_business_day(%Date{} = start_date) do
    Enum.find_value(1..14, fn offset ->
      date = Date.add(start_date, offset)
      dow = Date.day_of_week(date)
      if dow in 1..5, do: date, else: nil
    end) || Date.add(start_date, 1)
  end
end
