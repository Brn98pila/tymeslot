defmodule TymeslotWeb.Themes.Rhythm.Theme do
  @moduledoc """
  Rhythm theme implementation with video background and 4-slide compact flow.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  @behaviour TymeslotWeb.Themes.Core.Behaviour

  alias TymeslotWeb.Themes.Rhythm.Meeting.{Cancel, CancelConfirmed, Reschedule}
  alias TymeslotWeb.Themes.Rhythm.Payment.{Cancelled, Processing}

  @impl TymeslotWeb.Themes.Core.Behaviour
  def live_view_module do
    TymeslotWeb.Themes.Rhythm.Scheduling.Live
  end

  @impl TymeslotWeb.Themes.Core.Behaviour
  def metadata do
    %{
      preview_image: "/images/ui/theme-previews/rhythm-theme-preview.webp",
      description:
        dgettext(
          "dashboard_appearance",
          "Modern sliding design with video background and a 4-slide booking flow."
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
  defdelegate render_poll_action(assigns), to: TymeslotWeb.Themes.Rhythm.Poll.Voting, as: :render

  @impl TymeslotWeb.Themes.Core.Behaviour
  def render_payment_page(assigns, :processing), do: Processing.render(assigns)
  def render_payment_page(assigns, :cancelled), do: Cancelled.render(assigns)
end
