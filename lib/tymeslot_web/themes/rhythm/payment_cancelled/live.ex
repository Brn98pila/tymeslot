defmodule TymeslotWeb.Themes.Rhythm.PaymentCancelledLive do
  @moduledoc """
  Rhythm theme return page after a Stripe Checkout cancel.

  Tells the attendee the booking is not confirmed and that they may
  return to the host's booking page to try again.
  """

  use TymeslotWeb, :live_view

  alias Phoenix.LiveView
  alias TymeslotWeb.Themes.Rhythm.Theme, as: RhythmTheme
  alias TymeslotWeb.Themes.Shared.PaymentReturn

  @impl Phoenix.LiveView
  def mount(%{"meeting_id" => meeting_id}, _session, socket) do
    if LiveView.connected?(socket) do
      case PaymentReturn.lookup_for_cancel(meeting_id, "rhythm") do
        {:ok, %{meeting: meeting, rebook_path: rebook_path}} ->
          {:ok, assign(socket, loading: false, meeting: meeting, rebook_path: rebook_path)}

        {:error, _reason} ->
          {:ok, redirect(socket, to: ~p"/")}
      end
    else
      {:ok, assign(socket, loading: true, meeting: nil, rebook_path: nil)}
    end
  end

  @impl Phoenix.LiveView
  def render(assigns), do: RhythmTheme.render_payment_page(assigns, :cancelled)
end
