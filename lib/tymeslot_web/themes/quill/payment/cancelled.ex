defmodule TymeslotWeb.Themes.Quill.Payment.Cancelled do
  @moduledoc """
  Quill's shell for the payment-cancelled return page, around the shared
  `PaymentReturnComponents.cancelled_body/1`.
  """
  use Phoenix.Component

  alias TymeslotWeb.Themes.Shared.PaymentReturnComponents

  attr :rebook_path, :string, default: nil

  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <div class="quill-theme-wrapper theme-1" data-testid="quill-payment-cancelled">
      <div class="main-gradient theme-grid payment-page-layout">
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
