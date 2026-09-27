defmodule TymeslotWeb.Themes.Rhythm.PaymentProcessingLive do
  @moduledoc """
  Rhythm theme return page after a successful Stripe Checkout redirect.

  Subscribes to `meeting_payment:<id>` PubSub and flips to the confirmed
  view when the webhook handler broadcasts `:paid`. The webhook is the
  source of truth; this page never mutates state.

  Paid does not always mean confirmed: a meeting type can be both paid and
  approval-gated, in which case the webhook moves the meeting to
  `"awaiting_approval"` rather than `"confirmed"`
  (`CheckoutSessionCompleted.post_payment_status/1`).
  `handle_info(:paid, _)` and `handle_info(:expired, _)` (a failed or
  lapsed checkout) delegate to `PaymentReturn.refresh/1`, which re-fetches
  the meeting, not just the payment, so this page reads what the webhook
  wrote rather than assuming how the checkout ended.
  `PaymentReturn.outcome/3` then turns that state into what `render/1` shows.
  """

  use TymeslotWeb, :live_view

  alias TymeslotWeb.Themes.Rhythm.Theme, as: RhythmTheme
  alias TymeslotWeb.Themes.Shared.PaymentReturn

  @impl Phoenix.LiveView
  def mount(params, _session, socket) do
    PaymentReturn.mount_payment_processing(params, socket, "rhythm")
  end

  @impl Phoenix.LiveView
  def handle_info(message, socket) when message in [:paid, :expired] do
    {:noreply, PaymentReturn.refresh(socket)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def render(assigns), do: RhythmTheme.render_payment_page(assigns, :processing)
end
