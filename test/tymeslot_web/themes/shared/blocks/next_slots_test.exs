defmodule TymeslotWeb.Themes.Shared.Blocks.NextSlotsTest do
  @moduledoc """
  The soonest free times across days, for a journey that starts from time.
  Today is Wednesday 10 March 2027, in the week from Monday 8 March; slot
  values have the "9:00 AM" shape the availability layer produces.
  """
  use ExUnit.Case, async: true

  @moduletag :themes
  @moduletag :components

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias TymeslotWeb.Themes.Shared.Blocks.NextSlots

  @today ~D[2027-03-10]

  @week %{
    "2027-03-08" => ["9:00 AM"],
    "2027-03-10" => ["9:00 AM", "9:30 AM"],
    "2027-03-11" => [],
    "2027-03-12" => ["2:00 PM"],
    "2027-03-13" => ["10:00 AM"],
    "2027-03-14" => ["11:00 AM"]
  }

  setup do
    Gettext.put_locale(TymeslotWeb.Gettext, "en")
    :ok
  end

  defp render_slots(overrides \\ []) do
    assigns =
      Map.merge(
        %{id: "now-slots", week_slots: @week, today: @today, days: 3, target: nil},
        Map.new(overrides)
      )

    (&NextSlots.next_slots/1)
    |> render_component(assigns)
    |> Floki.parse_fragment!()
  end

  defp slots(doc, selector) do
    for slot <- Floki.find(doc, selector) do
      {slot |> Floki.attribute("data-date") |> hd(), slot |> Floki.attribute("data-time") |> hd()}
    end
  end

  test "offers the soonest days' times from today as slot facts" do
    doc = render_slots()

    assert slots(doc, ".next-slots__day:not([hidden]) [data-fact=slot]") == [
             {"2027-03-10", "9:00 AM"},
             {"2027-03-10", "9:30 AM"},
             {"2027-03-12", "2:00 PM"},
             {"2027-03-13", "10:00 AM"}
           ]

    assert Floki.attribute(doc, "[data-date='2027-03-12'][data-fact=slot]", "phx-click") ==
             ["select_slot"]
  end

  test "heads each day as a visitor says it" do
    headings =
      render_slots()
      |> Floki.find(".next-slots__day:not([hidden]) .next-slots__day-label")
      |> Enum.map(&(&1 |> Floki.text() |> String.trim()))

    assert headings == ["Today", "Fri 12", "Sat 13"]
  end

  test "keeps the further days in the page behind More times" do
    doc = render_slots()

    assert slots(doc, ".next-slots__day--extra[hidden] [data-fact=slot]") ==
             [{"2027-03-14", "11:00 AM"}]

    assert [more] = Floki.attribute(doc, "[data-testid=next-slots-more]", "phx-click")
    assert more =~ "remove_attr"
    assert more =~ "#now-slots .next-slots__day--extra"
  end

  test "has no More control when the soonest days are all there is" do
    assert Floki.find(render_slots(days: 5), "[data-testid=next-slots-more]") == []
  end

  test "marks the chosen time" do
    doc = render_slots(selected_date: "2027-03-12", selected_time: "2:00 PM")

    assert Floki.attribute(doc, "[data-date='2027-03-12'][data-time='2:00 PM']", "aria-pressed") ==
             ["true"]
  end

  test "asks for its week while it has none" do
    doc = render_slots(week_slots: nil)

    assert [mounted] = Floki.attribute(doc, "[data-testid=next-slots]", "phx-mounted")
    assert mounted =~ "load_week"
    assert doc |> Floki.find(".next-slots__loading") |> Floki.text() =~ "Loading available times"
  end

  test "offers the next week when nothing is free from today on" do
    doc = render_slots(week_slots: %{"2027-03-08" => ["9:00 AM"], "2027-03-12" => []})

    assert slots(doc, "[data-fact=slot]") == []

    assert Floki.attribute(doc, "[data-testid=next-slots-next-week]", "phx-click") == [
             "next_week"
           ]

    assert Floki.attribute(doc, "[data-testid=next-slots-next-week]", "data-intent") == ["later"]
  end

  test "marks only the control that moves the week as a period arrow" do
    doc = render_slots()

    assert Floki.find(doc, "[data-intent]") == []
    assert Floki.attribute(doc, "[data-testid=next-slots-more]", "data-intent") == []
  end

  test "offers no slot fact for a day before today" do
    doc = render_slots()

    assert Floki.find(doc, "[data-fact=slot][data-date='2027-03-08']") == []
    assert Enum.all?(Floki.attribute(doc, "[data-fact=slot]", "data-date"), &(&1 >= "2027-03-10"))
  end

  test "shows the week's fetch error" do
    doc = render_slots(error: "No time slots could be loaded. Please try again.")

    assert doc |> Floki.find(".next-slots__error") |> Floki.text() =~
             "No time slots could be loaded. Please try again."
  end
end
