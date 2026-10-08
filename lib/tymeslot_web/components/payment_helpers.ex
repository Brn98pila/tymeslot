defmodule TymeslotWeb.Components.PaymentHelpers do
  @moduledoc """
  Template helper for payment amounts that may be absent.

  Used by `TymeslotWeb.Dashboard.PaymentsSettingsComponent` and
  `TymeslotWeb.Components.Dashboard.Meetings.CancelMeetingModal`.
  """

  alias Tymeslot.MeetingPayments.Money

  @doc """
  Formats an integer cent amount with `Tymeslot.MeetingPayments.Money.format/3`.

  Returns an empty string when `cents` is not an integer or there is no
  currency, so a template can render a price that is not set yet without a
  guard.
  """
  @spec format_amount(integer() | term(), String.t() | nil) :: String.t()
  def format_amount(cents, currency) when is_integer(cents) and is_binary(currency),
    do: Money.format(cents, currency)

  def format_amount(_cents, _currency), do: ""
end
