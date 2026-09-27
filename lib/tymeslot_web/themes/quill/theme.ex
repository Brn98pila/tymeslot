defmodule TymeslotWeb.Themes.Quill.Theme do
  @moduledoc """
  Quill theme implementation with glassmorphism design and 4-step flow.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  @behaviour TymeslotWeb.Themes.Core.Behaviour

  alias TymeslotWeb.Themes.Quill.Meeting.{Cancel, CancelConfirmed, Reschedule}
  alias TymeslotWeb.Themes.Quill.Payment.{Cancelled, Processing}

  @impl TymeslotWeb.Themes.Core.Behaviour
  def live_view_module do
    TymeslotWeb.Themes.Quill.Scheduling.Live
  end

  @impl TymeslotWeb.Themes.Core.Behaviour
  def metadata do
    %{
      preview_image: "/images/ui/theme-previews/quill-theme-preview.webp",
      description:
        dgettext(
          "dashboard_appearance",
          "Glass morphism design with elegant transparency effects and a 4-step booking flow."
        )
    }
  end

  @impl TymeslotWeb.Themes.Core.Behaviour
  def render_meeting_action(assigns, action) do
    case action do
      :reschedule -> Reschedule.render(assigns)
      :cancel -> Cancel.render(assigns)
      :cancel_confirmed -> CancelConfirmed.render(assigns)
      _other -> raise "Unsupported meeting action: #{action}"
    end
  end

  @impl TymeslotWeb.Themes.Core.Behaviour
  defdelegate render_poll_action(assigns), to: TymeslotWeb.Themes.Quill.Poll.Voting, as: :render

  @impl TymeslotWeb.Themes.Core.Behaviour
  def render_payment_page(assigns, :processing), do: Processing.render(assigns)
  def render_payment_page(assigns, :cancelled), do: Cancelled.render(assigns)
end
