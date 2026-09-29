defmodule TymeslotWeb.Themes.Rhythm.Payment.Cancelled do
  @moduledoc """
  Rhythm's shell for the payment-cancelled return page, around the shared
  `PaymentReturnComponents.cancelled_body/1`.
  """
  use Phoenix.Component

  alias TymeslotWeb.Themes.Shared.PaymentReturnComponents

  attr :rebook_path, :string, default: nil

  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <div class="rhythm-theme-wrapper" data-testid="rhythm-payment-cancelled">
      <div class="payment-page-layout">
        <div class="payment-page-inner">
          <div class="payment-page-card">
            <div class="payment-page-card-body">
              <PaymentReturnComponents.cancelled_body rebook_path={@rebook_path} />
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
