defmodule TymeslotWeb.Themes.Core.Loader do
  @moduledoc """
  Resolves a theme id to its loaded theme module.

  There is no runtime callback check: every theme module declares
  `TymeslotWeb.Themes.Core.Behaviour`, so a missing callback is a compiler
  warning, which `--warnings-as-errors` turns into a failed build.
  """

  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias TymeslotWeb.Themes.Core.Registry
  require Logger

  @type load_result :: {:ok, module()} | {:error, term()}

  @doc """
  Loads the theme module registered for `theme_id`.
  """
  @spec load_theme(String.t()) :: load_result()
  def load_theme(theme_id) do
    with {:ok, theme} <- Registry.get_theme_by_id(theme_id),
         {:ok, module} <- ensure_loaded(theme.module) do
      {:ok, module}
    else
      {:error, :theme_not_found} = error ->
        Logger.error("Theme not found", theme_id: theme_id)
        error

      {:error, reason} = error ->
        Logger.error("Failed to load theme", theme_id: theme_id, reason: LogFormat.reason(reason))
        error
    end
  end

  @doc """
  Gets the scheduling LiveView module for a theme id, or `nil` when the id
  resolves to no theme.
  """
  @spec get_live_view_module(String.t()) :: module() | nil
  def get_live_view_module(theme_id) do
    case load_theme(theme_id) do
      {:ok, module} -> module.live_view_module()
      {:error, _reason} -> nil
    end
  end

  defp ensure_loaded(module) do
    case Code.ensure_loaded(module) do
      {:module, ^module} -> {:ok, module}
      {:error, reason} -> {:error, {:module_not_loaded, reason}}
    end
  end
end
