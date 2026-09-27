defmodule TymeslotWeb.Themes.Core.Behaviour do
  @moduledoc """
  The contract a booking theme implements.

  A theme owns presentation only: its scheduling LiveView, its metadata for
  the dashboard's theme picker, and the pages it draws around shared bodies
  (meeting management, poll voting, payment return). The booking flow is
  shared (`Shared.SchedulingLive`), and theme facts live in
  `Tymeslot.Themes.Catalog`.

  Completeness is checked by the compiler: a module declaring this behaviour
  without one of the callbacks gets a warning, which `--warnings-as-errors`
  turns into a failed build. There is no runtime check.
  """

  @doc "The theme's scheduling LiveView."
  @callback live_view_module() :: module()

  @doc """
  Presentation metadata for the dashboard's theme picker: `preview_image`, a
  path under `priv/static`, and `description`, translated into the current
  Gettext locale.
  """
  @callback metadata() :: %{preview_image: String.t(), description: String.t()}

  @doc """
  Renders a meeting management page: `:reschedule`, `:cancel` or
  `:cancel_confirmed`. Any other action raises.
  """
  @callback render_meeting_action(assigns :: map(), action :: atom()) ::
              Phoenix.LiveView.Rendered.t()

  @doc "Renders the public poll voting page."
  @callback render_poll_action(assigns :: map()) :: Phoenix.LiveView.Rendered.t()

  @doc """
  Renders a payment return page, `:processing` or `:cancelled`: the theme's
  shell around `Shared.PaymentReturnComponents`.
  """
  @callback render_payment_page(assigns :: map(), page :: :processing | :cancelled) ::
              Phoenix.LiveView.Rendered.t()
end
