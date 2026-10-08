defmodule TymeslotWeb.Test.FixtureTheme.ClipsPanel do
  @moduledoc """
  The fixture theme's dashboard panel for its `Clips` group: one upload form
  per clip, each sending `upload_asset` with its field, as the emblem's
  upload does. It keeps no UI state, so the `Panel` defaults stand.
  """
  use Phoenix.Component
  use TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.Panel

  alias TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.Panel

  @fields [:fixture_intro_clip_path, :fixture_outro_clip_path]

  @impl Panel
  def render(assigns) do
    assigns = assign(assigns, :fields, Enum.filter(@fields, &upload?(assigns, &1)))

    ~H"""
    <div data-testid="fixture-clips-panel">
      <p>Clips</p>
      <form
        :for={field <- @fields}
        id={"fixture-clip-upload-#{field}"}
        phx-change="upload_asset"
        phx-submit="upload_asset"
        phx-target={@myself}
        data-auto-upload="true"
      >
        <input type="hidden" name="asset_field" value={field} />
        <.live_file_input upload={@uploads[field]} />
        <button type="submit" class="hidden">Upload</button>
      </form>
    </div>
    """
  end

  defp upload?(assigns, field), do: Map.has_key?(assigns[:uploads] || %{}, field)
end
