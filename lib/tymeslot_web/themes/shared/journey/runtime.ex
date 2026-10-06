defmodule TymeslotWeb.Themes.Shared.Journey.Runtime do
  @moduledoc """
  The engine every theme's booking runs on: the parts of the flow that are
  no one fact's. The journey is `socket.assigns.journey`, which
  `SchedulingLive` assigns on mount.

  `transition_to/3` shows a moment or an outcome: it sets `:current_state`
  and, for a moment, runs each collected fact's `enter/2` with `params` (the
  URL's, or `%{}` for a move inside the page). The navigators and
  `BookingFlow` move through it.
  """

  import Phoenix.Component, only: [assign: 3]

  alias Phoenix.LiveView.Socket
  alias TymeslotWeb.Themes.Shared.Journey

  @doc "Shows the moment or outcome `key`, running what its facts set up."
  @spec transition_to(Socket.t(), atom(), map()) :: Socket.t()
  def transition_to(socket, key, params) do
    socket = assign(socket, :current_state, key)

    case Journey.moment(socket.assigns.journey, key) do
      nil -> socket
      moment -> Enum.reduce(moment.collects, socket, &Journey.fact!(&1).enter(&2, params))
    end
  end
end
