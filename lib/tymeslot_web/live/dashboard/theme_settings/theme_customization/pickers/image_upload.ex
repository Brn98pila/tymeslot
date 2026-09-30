defmodule TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.Pickers.ImageUpload do
  @moduledoc """
  The upload form for one image asset field of a theme's spec: a file input
  bound to the field's upload (declared by `AssetUploads`, named after the
  field), each entry's progress and errors, and the accepted formats. It
  sends `upload_asset` on change and on submit, with a hidden `asset_field`
  input naming the field, so the customisation component saves the file
  into it (`ThemeCustomizations.attach_asset/4`). The background's image
  picker and the logo panel use it.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  attr :id, :string, required: true, doc: "the form's DOM id"
  attr :field, :atom, required: true, doc: "the image asset field the upload saves into"
  attr :uploads, :map, default: nil, doc: "the component's uploads, keyed by asset field"
  attr :myself, :any, required: true

  @spec image_upload(map()) :: Phoenix.LiveView.Rendered.t()
  def image_upload(assigns) do
    assigns = assign(assigns, :upload, assigns.uploads && assigns.uploads[assigns.field])

    ~H"""
    <form
      id={@id}
      phx-submit="upload_asset"
      phx-change="upload_asset"
      phx-target={@myself}
      data-auto-upload="true"
      class="flex flex-col items-center gap-6"
    >
      <input type="hidden" name="asset_field" value={@field} />
      <div class="w-full max-w-md">
        <%= if @upload do %>
          <div class="relative group/upload">
            <.live_file_input
              upload={@upload}
              class="absolute inset-0 w-full h-full opacity-0 cursor-pointer z-20"
            />
            <div class="btn-secondary w-full py-4 flex items-center justify-center gap-3">
              <svg
                class="w-5 h-5 text-turquoise-600"
                fill="none"
                stroke="currentColor"
                viewBox="0 0 24 24"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2.5"
                  d="M4 16v1a3 3 0 003 3h10a3 3 0 003-3v-1m-4-8l-4-4m0 0L8 8m4-4v12"
                />
              </svg>
              <span>{dgettext("dashboard_appearance", "Select Image")}</span>
            </div>
          </div>

          <%= for err <- upload_errors(@upload) do %>
            <div class="mt-4 p-3 bg-red-50 border border-red-100 rounded-token-xl text-red-600 text-xs font-bold flex items-center gap-2">
              <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2.5"
                  d="M12 8v4m0 4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"
                />
              </svg>
              {Phoenix.Naming.humanize(err)}
            </div>
          <% end %>

          <%= for entry <- @upload.entries do %>
            <div class="mt-6 p-4 bg-white rounded-token-2xl border-2 border-tymeslot-100 shadow-sm">
              <div class="flex items-center justify-between mb-2">
                <span class="text-tymeslot-700 font-black text-token-xs uppercase tracking-wider truncate mr-4">
                  {entry.client_name}
                </span>
                <span class="text-turquoise-600 font-black text-token-xs">{entry.progress}%</span>
              </div>
              <div class="bg-tymeslot-100 rounded-full h-2 overflow-hidden shadow-inner">
                <div
                  class="bg-linear-to-r from-turquoise-500 to-cyan-500 h-full transition-all duration-300"
                  style={"width: #{entry.progress}%"}
                >
                </div>
              </div>

              <%= for err <- upload_errors(@upload, entry) do %>
                <div class="mt-2 p-3 bg-red-50 border border-red-100 rounded-token-xl text-red-600 text-xs font-bold flex items-center gap-2">
                  <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      stroke-width="2.5"
                      d="M12 8v4m0 4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"
                    />
                  </svg>
                  {Phoenix.Naming.humanize(err)}
                </div>
              <% end %>
            </div>
          <% end %>
        <% else %>
          <div class="btn-secondary w-full opacity-50 cursor-not-allowed py-4">
            {dgettext("dashboard_appearance", "Upload not available")}
          </div>
        <% end %>
        <button type="submit" id={"#{@id}-submit"} class="hidden">
          {dgettext("dashboard_appearance", "Upload Image")}
        </button>
      </div>

      <p class="text-token-2xs font-black text-tymeslot-400 uppercase tracking-[0.2em]">
        {dgettext("dashboard_appearance", "JPG, PNG or WebP. Max 5MB.")}
      </p>
    </form>
    """
  end
end
