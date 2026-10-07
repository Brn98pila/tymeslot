defmodule TymeslotWeb.Themes.Shared.Blocks.DayChipsTest do
  @moduledoc """
  The next free days as chips, from the month's availability map. Today is
  Wednesday 10 March 2027.
  """
  use ExUnit.Case, async: true

  @moduletag :themes
  @moduletag :components

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias TymeslotWeb.Themes.Shared.Blocks.DayChips

  @today ~D[2027-03-10]

  @availability %{
    "2027-03-09" => true,
    "2027-03-10" => true,
    "2027-03-11" => true,
    "2027-03-12" => false,
    "2027-03-13" => true,
    "2027-03-20" => true
  }

  setup do
    Gettext.put_locale(TymeslotWeb.Gettext, "en")
    :ok
  end

  defp render_chips(overrides \\ []) do
    assigns =
      Map.merge(
        %{availability: @availability, today: @today, count: 3, target: nil},
        Map.new(overrides)
      )

    (&DayChips.day_chips/1)
    |> render_component(assigns)
    |> Floki.parse_fragment!()
  end

  defp chips(doc) do
    for chip <- Floki.find(doc, "[data-fact=date]") do
      {chip |> Floki.attribute("data-value") |> hd(), chip |> Floki.text() |> String.trim()}
    end
  end

  test "offers the first free days from today, labelled as a visitor says them" do
    assert chips(render_chips()) == [
             {"2027-03-10", "Today"},
             {"2027-03-11", "Tomorrow"},
             {"2027-03-13", "Sat 13"}
           ]
  end

  test "sends select_date and names each chip by its full date" do
    doc = render_chips()

    assert Floki.attribute(doc, "[data-value='2027-03-13']", "phx-click") == ["select_date"]
    assert Floki.attribute(doc, "[data-value='2027-03-13']", "phx-value-date") == ["2027-03-13"]

    assert Floki.attribute(doc, "[data-value='2027-03-13']", "aria-label") == [
             "Saturday, March 13, 2027"
           ]

    assert Floki.attribute(doc, "[role=group]", "aria-label") == ["Select a Date"]
  end

  test "marks the chosen day" do
    doc = render_chips(selected_date: "2027-03-11")

    assert Floki.attribute(doc, "[data-value='2027-03-11']", "aria-pressed") == ["true"]
    assert Floki.attribute(doc, "[data-value='2027-03-10']", "aria-pressed") == ["false"]
  end

  test "says it is loading before the month's availability arrives" do
    doc = render_chips(availability: nil)

    assert chips(doc) == []
    assert doc |> Floki.find(".day-chips__loading") |> Floki.text() =~ "Loading available times"
  end

  test "says when no day is free" do
    doc = render_chips(availability: %{"2027-03-11" => false})

    assert chips(doc) == []
    assert doc |> Floki.find(".day-chips__empty") |> Floki.text() =~ "No times available"
  end
end
