defmodule TymeslotWeb.Test.ShowcaseTheme.Payment.Processing do
  @moduledoc "The showcase theme's shell for the payment-processing return page."
  use Phoenix.Component

  alias TymeslotWeb.Themes.Shared.PaymentReturnComponents

  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <div class="fixture-theme-wrapper booker-page" data-testid="showcase-payment-processing">
      <section class="booker-card">
        <PaymentReturnComponents.processing_body
          loading={@loading}
          payment={@payment}
          meeting={@meeting}
          rebook_path={@rebook_path}
        />
      </section>
    </div>
    """
  end
end

defmodule TymeslotWeb.Test.ShowcaseTheme.Payment.Cancelled do
  @moduledoc "The showcase theme's shell for the payment-cancelled return page."
  use Phoenix.Component

  alias TymeslotWeb.Themes.Shared.PaymentReturnComponents

  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <div class="fixture-theme-wrapper booker-page" data-testid="showcase-payment-cancelled">
      <section class="booker-card">
        <PaymentReturnComponents.cancelled_body rebook_path={@rebook_path} />
      </section>
    </div>
    """
  end
end
