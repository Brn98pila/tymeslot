defmodule Tymeslot.Infrastructure.AdminAlerts.RegisteredAlertTypesTest do
  @moduledoc """
  Every alert type raised in Core's code is registered in `AlertTypes`. An
  unregistered one still sends, but as a generic "General" warning with no
  dedup rule, and the type spec no longer catches a mistyped name.
  """

  use ExUnit.Case, async: true

  @moduletag :infrastructure

  import ExUnit.CaptureLog

  alias Tymeslot.Infrastructure.AdminAlerts
  alias Tymeslot.Infrastructure.AdminAlerts.AlertTypes

  @call ~r/AdminAlerts\.(?:report|send_alert)\(\s*:(\w+)/

  test "every alert type raised in lib/ is registered" do
    raised =
      "lib/**/*.ex"
      |> Path.wildcard()
      |> Enum.flat_map(&Regex.scan(@call, File.read!(&1), capture: :all_but_first))
      |> Enum.map(fn [name] -> String.to_atom(name) end)
      |> Enum.uniq()

    assert raised != []
    assert Enum.reject(raised, &AlertTypes.get/1) == []
  end

  test "an unregistered type is logged as such" do
    log =
      capture_log(fn ->
        AdminAlerts.send_alert(:no_such_alert_type, %{summary: "test"})
      end)

    assert log =~ "not registered"
  end
end
