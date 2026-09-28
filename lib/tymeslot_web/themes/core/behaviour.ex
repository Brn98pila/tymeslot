defmodule TymeslotWeb.Themes.Core.Behaviour do
  @moduledoc """
  The contract a booking theme implements.

  A theme owns presentation only: its scheduling LiveView, its metadata for
  the dashboard's theme picker, and the pages it draws around shared bodies
  (meeting management, poll voting, payment return). The booking flow is
  shared (`Shared.SchedulingLive`), and theme facts live in
  `Tymeslot.Themes.Catalog`.

  A theme module implements this through `use TymeslotWeb.Themes.Core.Theme`,
  which generates every callback and dispatches the renders to conventional
  modules under the theme's namespace. Completeness is therefore checked by
  the compiler; there is no runtime check.
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

  @doc """
  Draws the theme in the onboarding wizard. `assigns.variant` is:

    * `:thumbnail`, the theme step's picker tile, with `primary` (the
      scheme's primary colour);
    * `:card`, the live preview card, with `colors`, `slots`, `locale`,
      `highlight_card`, `highlight_slots` and a `header` slot holding the
      shared identity header the card is drawn around.

  Optional: `use TymeslotWeb.Themes.Core.Theme` supplies the generic mock
  (`TymeslotWeb.OnboardingLive.PreviewParts.generic/1`), and the wizard falls
  back to it for a module without this callback.
  """
  @callback onboarding_preview(assigns :: map()) :: Phoenix.LiveView.Rendered.t()

  @optional_callbacks onboarding_preview: 1
end
