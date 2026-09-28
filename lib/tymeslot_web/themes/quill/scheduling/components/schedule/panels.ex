defmodule TymeslotWeb.Themes.Quill.Scheduling.Components.Schedule.Panels do
  @moduledoc """
  The Quill schedule step's timezone selector.
  """
  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Timezones
  alias TymeslotWeb.Themes.Shared.TimezoneHelpers

  import TymeslotWeb.Components.CoreComponents
  import TymeslotWeb.Components.FlagHelpers

  # ========== TIMEZONE SELECTOR ==========

  attr :user_timezone, :string, required: true
  attr :timezone_search, :string, required: true
  attr :timezone_dropdown_open, :boolean, required: true
  attr :target, :any, required: true
  attr :locale, :string, required: true

  @spec timezone_selector(map()) :: Phoenix.LiveView.Rendered.t()
  def timezone_selector(assigns) do
    ~H"""
    <div class="relative" data-locale={@locale}>
      <%!-- Visual label only: it names no control (the trigger below carries its
           own accessible name), so it must not be a <label> element. --%>
      <div class="timezone-label">
        <div class="timezone-label-content">
          <svg class="timezone-label-icon" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z"
            />
          </svg>
          {dgettext("booking", "Your timezone")}
        </div>
      </div>

      <div class="timezone-dropdown-wrapper">
        <.dropdown
          id="quill-timezone-dropdown"
          open={@timezone_dropdown_open}
          on_toggle="toggle_timezone_dropdown"
          on_close="close_timezone_dropdown"
          target={@target}
          role="dialog"
          panel_label={dgettext("booking", "Select timezone")}
          trigger_class="timezone-trigger"
          class="timezone-dropdown"
          unstyled={true}
        >
          <:trigger>
            <span class="sr-only">{dgettext("booking", "Your timezone")}:</span>
            <div class="timezone-trigger-row">
              <div class="timezone-trigger-info">
                <.timezone_flag timezone={@user_timezone} class="timezone-flag" fallback_icon="🌐" />
                <div class="timezone-trigger-text">
                  <div class="timezone-name">
                    {Timezones.format(@user_timezone)}
                  </div>
                  <div class="timezone-time-display timezone-time-inline">
                    {dgettext("booking", "%{time} local time",
                      time: TimezoneHelpers.format_local_time(@user_timezone)
                    )}
                  </div>
                </div>
              </div>
              <div class="timezone-meta">
                <div class="timezone-offset-badge">
                  {Timezones.utc_offset(@user_timezone)}
                </div>
                <svg
                  class={["timezone-chevron", @timezone_dropdown_open && "open"]}
                  fill="none"
                  stroke="currentColor"
                  viewBox="0 0 24 24"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M19 9l-7 7-7-7"
                  />
                </svg>
              </div>
            </div>
          </:trigger>
          <:panel>
            <div class="timezone-search-wrapper">
              <input
                id="timezone-search"
                type="text"
                class="timezone-search"
                phx-keyup="search_timezone"
                phx-target={@target}
                name="search"
                value={@timezone_search}
                placeholder={dgettext("booking", "Search cities, countries, or timezones...")}
                aria-label={dgettext("booking", "Search timezones")}
                autocomplete="off"
                phx-hook="AutoFocus"
              />
            </div>
            <div class="timezone-options scroll-y">
              <%= for {label, value, offset} <- Timezones.search(@timezone_search) do %>
                <button
                  class="timezone-option"
                  phx-click="change_timezone"
                  phx-value-timezone={value}
                  phx-target={@target}
                  type="button"
                >
                  <div class="timezone-option-content">
                    <.timezone_flag
                      timezone={value}
                      class="timezone-option-flag"
                      fallback_icon="🌐"
                    />
                    <div class="timezone-option-text">
                      <div class="timezone-option-label">{label}</div>
                      <div class="timezone-option-offset">{offset}</div>
                    </div>
                  </div>
                </button>
              <% end %>
            </div>
          </:panel>
        </.dropdown>
      </div>
    </div>
    """
  end
end
