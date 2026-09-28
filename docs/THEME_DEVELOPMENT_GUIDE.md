# Theme Development Guide

This guide explains how to create new themes for Tymeslot.

## Architecture Overview

The theme system uses a centralized registry pattern that eliminates magic strings and provides type-safe theme access.

### Key Components

1. **Theme Catalog** (`Tymeslot.Themes.Catalog`) - Domain source of truth for theme *facts* (id, key, name, customisation spec, status)
2. **Theme Registry** (`TymeslotWeb.Themes.Core.Registry`) - Web layer; merges catalog facts with presentation bindings (the theme module)
3. **Theme Behaviour** (`TymeslotWeb.Themes.Core.Behaviour`) - The contract a theme module fulfils; `use TymeslotWeb.Themes.Core.Theme` generates it
4. **SchedulingLive Macro** (`TymeslotWeb.Themes.Shared.SchedulingLive`) - Injects all common LiveView callbacks; a theme's `live.ex` is built on it
5. **Shared State Machine** (`TymeslotWeb.Themes.Shared.StateMachineHelpers`) - Owns state transitions and routing for all themes (no per-theme state machine)
6. **Shared Context** (`TymeslotWeb.Themes.Shared.*`) - Shared helpers, handlers, and components
7. **Customisation spec** (`Tymeslot.ThemeCustomizations.Spec`) - Per-theme option groups, defaults, validation and CSS tokens; each Catalog entry names its spec module
8. **Dispatcher & Loader** (`TymeslotWeb.Themes.Core.Dispatcher`, `TymeslotWeb.Themes.Core.Loader`) - Systems for dynamically loading and dispatching theme actions
9. **Wrapper Components** (per-theme): the theme's background and wrapper classes around the shared `Shared.Components.ThemeShell`, which renders the page chrome

## Quick Reference

### File Structure for a Theme

```
lib/tymeslot_web/themes/[theme_name]/
├── theme.ex                    # One `use TymeslotWeb.Themes.Core.Theme`
├── onboarding_preview.ex        # Optional: the theme in the onboarding wizard
├── scheduling/
│   ├── live.ex                 # Main LiveView (uses the SchedulingLive macro)
│   ├── wrapper.ex              # Background and wrapper classes around ThemeShell
│   └── components/
│       ├── overview_component.ex
│       ├── schedule_component.ex
│       ├── custom_questions_component.ex   # Renders the conditional :questions step
│       ├── booking_component.ex
│       └── confirmation_component.ex
├── meeting/
│   ├── reschedule.ex
│   ├── cancel.ex
│   └── cancel_confirmed.ex
├── poll/
│   └── voting.ex               # Poll voting page shell
└── payment/                    # Payment return page shells (Stripe success / cancel)
    ├── processing.ex
    └── cancelled.ex
```

> **No per-theme `state_machine.ex`.** State transitions live in the shared
> `TymeslotWeb.Themes.Shared.StateMachineHelpers`. Both Quill and Rhythm have
> deleted their local state machine. See [Common Patterns](#common-patterns).
>
> **Payment return pages are shared.** `Shared.PaymentReturnLive.Processing` and `.Cancelled` serve `/themes/<key>/payment-processing/<id>` and `/themes/<key>/payment-cancelled/<id>` for every theme, assigning `:theme_id` from the slug so the layout loads the theme's own stylesheet. A theme only draws its shell, in `payment/processing.ex` and `payment/cancelled.ex`, around `Shared.PaymentReturnComponents`; it adds no route and no LiveView.
>
> Themes may add their own internal structure beyond the above; Rhythm, for
> example, keeps a theme-local `shared/` directory (`organizer_header.ex`) for
> components reused only within that theme.

```
assets/css/scheduling/themes/[theme_name]/
├── theme.css                   # Main entry point (imports shared primitives + modules)
└── modules/
    ├── variables.css           # Design tokens (colors, spacing, typography)
    ├── base.css                # html, body, theme wrapper, root grid
    ├── iframe.css              # Iframe shell rules
    ├── typography.css          # Text styles with fluid clamp() sizes
    ├── video.css               # Video background (if supported)
    ├── overview.css            # Organizer profile + avatar
    ├── calendar.css            # Calendar grid + container queries
    ├── time-slots.css          # Time slot grid + container queries
    ├── schedule-header.css     # Schedule header + timezone selector
    ├── booking-form.css        # Booking form + container queries
    ├── custom-questions.css    # Custom-questions step styling
    ├── confirmation.css        # Confirmation + container queries
    └── language-switcher.css   # Language switcher (theme-specific treatment)
```

> Components both themes style alike (preview and approval notices, polls,
> payment return pages, guest and location fields, language switcher
> structure, slot list, timezone picker) are not per-theme modules: their CSS
> lives in `assets/css/scheduling/shared/components/`, which each `theme.css`
> imports, and a theme styles them by defining the tokens each file lists in
> its header (see *Token contract*).

> The module breakdown is **per-theme, not canonical** — themes are free to split
> further. Quill (glassmorphism) splits its UI into `glass-card.css`, `buttons.css`,
> `animations.css`, `spinner.css`, `steps.css`, `timezone.css`, `meeting-details.css`,
> and `text-utilities.css`; Rhythm keeps a single `components.css`. Only the broad
> concerns above are common to both. The booking-form file is `booking-form.css`
> (not `booking.css`).

> **Never name a Tailwind utility in a theme selector** (`.text-3xl`, `.font-bold`, `.container`, `.hidden`, or a compound hook such as `.grid.grid-cols-7`). Theme modules are unlayered, so such a rule overrides that utility on every element of the booking page, shared and core components included. Put a theme or BEM class on the element (`quill-container`, `calendar-month-grid`, `step-label--current`) and style that; element selectors (`h1`) are fine.

### Behaviour Callbacks

Generated by `use TymeslotWeb.Themes.Core.Theme` (see Quick Start step 3):

```elixir
@callback live_view_module() :: module()
@callback metadata() :: %{preview_image: String.t(), description: String.t()}
@callback render_meeting_action(map(), atom()) :: Phoenix.LiveView.Rendered.t()
@callback render_poll_action(map()) :: Phoenix.LiveView.Rendered.t()
@callback render_payment_page(map(), :processing | :cancelled) :: Phoenix.LiveView.Rendered.t()
@callback onboarding_preview(map()) :: Phoenix.LiveView.Rendered.t()  # optional
```

`onboarding_preview/1` draws the theme in the onboarding wizard (`:thumbnail` for the picker tile, `:card` for the live preview card around a shared `header` slot). It defaults to a generic mock; Quill and Rhythm implement it in `themes/<theme>/onboarding_preview.ex` with the helpers in `TymeslotWeb.OnboardingLive.PreviewParts`.

### Shared Modules You'll Use

| Module | Purpose |
|--------|---------|
| `LiveHelpers.Mount` | Mounting the scheduling LiveView and applying URL parameters (timezone, organiser, customisation, owner preview, calendar subscription) |
| `LiveHelpers.StepEntry` | What entering the schedule, questions and booking steps sets up, and meeting-type assignment |
| `LiveHelpers.Tracking` | First-touch UTM and referrer attribution (`assign_tracking/2`, `tracking_path/2`) |
| `EventHandlers` | Page-level events outside the steps: language switcher, timezone search |
| `SchedulingFlow` | The booking flow itself: every step event, step transitions (`transition_to/3`), step entry (`handle_state_entry/3`) and step-indicator navigation (`navigate_to_step/2`) |
| `InfoHandlers` | The LiveView's mailbox: `route/2` dispatches availability results, slot loading, calendar refreshes and payment broadcasts |
| `StepEvents` | `update/2` and `handle_event/3` every step component delegates to; defines the canonical event names a step template may use |
| `SchedulingInit` | Socket state initialization — `assign_theme_state/1` for full scheduling state (prefer this), `assign_base_state/1` for core-only assigns |
| `BookingFlow` | Form validation and submission |
| `LocalizationHelpers` | Date/time/duration formatting: `format_date/1`, `format_duration/1`, `format_booking_datetime/3`, `format_time_by_locale/1` (respects locale 12h/24h setting — always use this for time slot display), `day_name_short/1` (localized weekday abbreviations), `get_week_display/1` (formatted week range string). `format_advance_booking_days/1` (the booking-window phrase in the schedule header, e.g. "2 weeks in advance"), `weekday_headers/0` (translated three-character weekday headers, Sunday first, matching the month grid). Meeting types arrive pre-ordered by the user's configured `sort_order` — never re-sort them in theme components. |
| `BookingText` | The overview step's introductory copy, and `duration_label/1`: the meeting length a step shows, the meeting type's own duration first, else the selected duration. Use it rather than choosing between the two in a template. |
| `ConfirmationText` | What the confirmation step announces: `status/1` (`:held`, `:rescheduled` or `:confirmed`; a held booking wins over a reschedule), `held_message/2` and `organizer_fragment/1`. The theme keeps its own headline per status. |
| `Tymeslot.Timezones` | Human-readable timezone display: `Timezones.format/1` — use this in confirmation and booking components instead of string-splitting the IANA timezone identifier |
| `TymeslotWeb.Live.Scheduling.CalendarHelpers` | Calendar/week day generation (`get_week_days/4` — pass `@user_timezone`), `anchor_on_today/1` (opens the calendar on today in the visitor's timezone; never compute "today" in a theme), `anchor_on/2` (positions the month and week on a date), `anchor_on_selection/1` (the schedule-step opening: a bookable chosen or linked day, else today) and `follow_timezone_change/1`, week and month navigation (`handle_week_navigation/2`, `handle_month_navigation/2`; both are shared schedule events, so a theme only renders buttons sending `prev_week`/`next_week` or `prev_month`/`next_month`), availability fetching, slot parsing, `display_range/2` for visible date boundaries. **Note:** this lives under `live/scheduling/`, not `themes/shared/`. |
| `TymeslotWeb.Live.Scheduling.CalendarNavigation` | Navigation boundary checks: `prev_month_disabled?/3`, `next_month_disabled?/4` (pass `@organizer_profile.advance_booking_days`), `prev_week_disabled?/2`, `next_week_disabled?/3` (pass `advance_booking_days`) — wire these to nav button `disabled` attributes. Also under `live/scheduling/`. |
| `StateMachineHelpers` | Shared state model and transition logic — `default_states/0`, `states_for/1` (5-step flow when the meeting type has custom fields, 4-step otherwise), `determine_initial_state/1`, `can_navigate_to_step?/3`, `validate_state_transition/3`. Replaces the deleted per-theme state machines. |
| `PathHandlers` | Navigation with locale preservation; `organizer_scheduling_path/1` for back-to-calendar links in cancel/reschedule pages; `calendar_ics_path/1` for the confirmation step's add-to-calendar link (`nil` until the meeting exists, which is what hides the link) |
| `Customization.Helpers` | Wrapper background/customization helpers. Call `prepare_wrapper_assigns/1` once at the top of your wrapper (it derives `@has_video_background`, `@video_poster`, `@show_language_switcher`), then render `ThemeShell` with the derived assigns; use `get_background_style/1` for the inline gradient/colour/image style. There is no `generate_custom_css` — the `custom_css` string arrives as an assign already. |
| `Customization.Video` | Video source generation — `render_preset_video_sources/1` and `render_upload_video_sources/1` build the `<source>` markup for a preset or an uploaded background |
| `LocaleHandler` | Applies a locale switch to the socket — `handle_locale_change/2`. The language switcher's locale list comes from `Tymeslot.Locales.supported/0` (each entry a `%{code:, name:, country_code:}` map) |
| `SchedulingLive` | Shared LiveView macro: `use TymeslotWeb.Themes.Shared.SchedulingLive, wrapper: &Wrapper.x/1, steps: %{…}` generates every callback and `render/1`; a theme's `live.ex` is only this `use` |
| `SchedulingPage` | The generated `render/1`: wrapper around the current step, readiness/error message, awaiting-payment screen, overview fallback |
| `VideoSources` | Shared component rendering `<source>` elements for video backgrounds; import and use `<.video_sources theme_customization={@theme_customization} />` in your wrapper |
| `Shared.Components.MeetingDetails` | Shared `meeting_detail_rows/1` component for cancel/reschedule pages; renders date, time, timezone, and organizer rows with icons |
| `Shared.Components.AwaitingPayment` | Shared `awaiting_payment/1` component for the transitional `:awaiting_payment` state in paid embedded bookings — `<AwaitingPayment.awaiting_payment checkout_url={@awaiting_payment_checkout_url} />` |
| `Shared.CustomQuestions.{Engine, Events, Inputs.Renderer}` | Shared engine, event delegation, and input renderers for the custom-questions step. Your theme's `CustomQuestionsComponent` provides the chrome and delegates `handle_event` to `Events`; `Inputs.Renderer` renders each field type. |

## Quick Start

### 1. Create Theme Directory Structure

Create the following directory structure for your new theme:

```
lib/tymeslot_web/themes/aurora/
├── scheduling/
│   ├── components/
│   │   ├── booking_component.ex
│   │   ├── confirmation_component.ex
│   │   ├── custom_questions_component.ex
│   │   ├── overview_component.ex
│   │   └── schedule_component.ex
│   ├── live.ex                 # No state_machine.ex — StateMachineHelpers is shared
│   └── wrapper.ex              # Background and wrapper classes around ThemeShell
├── meeting/
│   ├── cancel.ex
│   ├── cancel_confirmed.ex
│   └── reschedule.ex
├── poll/
│   └── voting.ex
├── payment/
│   ├── cancelled.ex
│   └── processing.ex
└── theme.ex

assets/css/scheduling/themes/aurora/
├── modules/
│   ├── variables.css           # Design tokens (colors, spacing, typography)
│   ├── base.css                # Root layout, theme wrapper
│   ├── iframe.css              # Iframe shell rules (required)
│   ├── typography.css          # Text styles with fluid clamp() sizes
│   ├── video.css               # Video background (if supported)
│   ├── overview.css            # Organizer profile (optional)
│   ├── calendar.css            # Calendar grid + container queries
│   ├── time-slots.css          # Time slot grid + container queries
│   ├── schedule-header.css     # Schedule header + timezone selector
│   ├── booking-form.css        # Booking form + container queries
│   ├── custom-questions.css    # Custom-questions step
│   ├── confirmation.css        # Confirmation step
│   ├── components.css          # Buttons, inputs, duration cards (or split further)
│   └── language-switcher.css   # Language dropdown
└── theme.css
```

**Tip**: Copy an existing theme (Quill or Rhythm) as a starting point and modify it.

### 2. Register Your Theme

Theme registration is split across **two** modules so the dependency only ever
flows web → domain:

**a. Theme facts** — add an entry to `@themes` in
`lib/tymeslot/themes/catalog.ex` (pure domain data: no module, CSS,
or image references):

```elixir
aurora: %{
  id: "3",
  key: :aurora,
  name: "Aurora",
  heading_style: :generic, # or :named, to open with "Schedule with <organiser>"
  customization_spec: Tymeslot.ThemeCustomizations.AuroraSpec,
  status: :active
}
```

Start a new theme at `status: :beta`: it is hidden from the theme pickers but
reachable with `?theme=<id>`. Switch it to `:active` when it is ready to offer.

The description shown in the dashboard is the theme's own, translated, not a
catalogue fact.

**b. Presentation bindings** — add an entry to `@bindings` (keyed by theme **id**)
in `lib/tymeslot_web/themes/core/registry.ex`:

```elixir
"3" => TymeslotWeb.Themes.Aurora.Theme
```

`Registry` joins the two at compile time (`Catalog.all/0` ⨝ `@bindings`) into the
`theme_definition` the web layer consumes. Nothing else is bound: the stylesheet
path (`/assets/scheduling-theme-aurora.css`) and the `aurora-theme` class derive
from the key, and the picker's preview image and description come from the theme
module's `metadata/0`. So the theme's Tailwind profile in `config/config.exs`
must write exactly `../priv/static/assets/scheduling-theme-aurora.css`, as the
`quill` and `rhythm` profiles do. Domain code (profiles, theme customisations)
reads facts from `Catalog` directly and never reaches into the web layer.

### 3. Implement Required Functions

Your theme module is one `use`:

```elixir
defmodule TymeslotWeb.Themes.Aurora.Theme do
  @moduledoc """
  Aurora: northern lights design with a 4-step booking flow.
  """

  use TymeslotWeb.Themes.Core.Theme,
    live_view: TymeslotWeb.Themes.Aurora.Scheduling.Live,
    preview_image: "/images/ui/theme-previews/aurora-theme-preview.webp",
    description:
      dgettext_noop("dashboard_appearance", "Northern lights design with a 4-step booking flow.")
end
```

`use TymeslotWeb.Themes.Core.Theme` declares `TymeslotWeb.Themes.Core.Behaviour` and generates every callback. The render callbacks dispatch by convention to `render/1` in modules under your theme's namespace: `Meeting.Reschedule`, `Meeting.Cancel`, `Meeting.CancelConfirmed`, `Poll.Voting`, `Payment.Processing` and `Payment.Cancelled`. A missing one is a compile warning, which the build treats as an error. Override a callback (with `@impl TymeslotWeb.Themes.Core.Behaviour`) only if your theme needs a different mapping. An override replaces every clause of that callback, so one that handles only some pages or actions must call `super/2` for the rest. The description must be a `dgettext_noop/2` call; `metadata/0` translates it at call time.

### 4. Test It Works

Add the theme to `TymeslotWeb.ThemeTestMatrix`. `test/tymeslot_web/themes/theme_contract_test.exs`
then holds it to the contract (LiveView, picker metadata, meeting, poll and payment
pages), and the shared flow suites run it through a booking:

```bash
mix test test/tymeslot_web/themes/theme_contract_test.exs
# Run the production checklist
mix test test/tymeslot_web/live/themes/theme_production_checklist_test.exs
```

This will verify:
- All meeting types are displayed
- Theme handles edge cases (no meetings, long names)
- Basic mobile responsiveness
- Acceptable load times

## CSS Architecture

### Modular Structure

Themes use a **modular CSS architecture** located in `assets/css/scheduling/`:

```
assets/css/scheduling/
├── shared/                        # Shared by every theme
│   ├── entry.css                 # Imported first by every theme.css: Tailwind, primitives, variants, @source
│   ├── tokens.css                # The token contract and the derived tokens
│   ├── reset.css                 # CSS reset
│   ├── layout.css                # Border-radius scale, display helpers, status screens
│   ├── utilities.css             # Shared utility classes
│   ├── brand-tokens.css          # Tailwind @theme block for the reCAPTCHA notice
│   ├── background-motion.css     # Background video pause/play toggle
│   ├── embed.css                 # Embed shell rules (booker hook classes)
│   └── components/               # Shared component styles (structure and states; themes set tokens)
│       ├── approval-notice.css
│       ├── booking-fields.css
│       ├── language-switcher.css
│       ├── payment-pages.css
│       ├── polls.css
│       ├── preview-notice.css
│       ├── slot-list.css
│       └── timezone-picker.css
└── themes/
    ├── quill/                         # Quill theme (glassmorphism) — fine-grained split
    │   ├── modules/
    │   │   ├── variables.css         # Design tokens
    │   │   ├── base.css              # Root layout, theme wrapper
    │   │   ├── iframe.css            # Iframe shell rules
    │   │   ├── video.css             # Video background
    │   │   ├── typography.css        # Text styles
    │   │   ├── animations.css        # Keyframes / transitions
    │   │   ├── glass-card.css        # Glassmorphism container (container query context)
    │   │   ├── buttons.css           # Buttons
    │   │   ├── spinner.css           # Loading spinner
    │   │   ├── meeting-details.css   # Meeting detail rows
    │   │   ├── text-utilities.css    # Text helpers
    │   │   ├── steps.css             # Step indicator
    │   │   ├── schedule-header.css   # Schedule header
    │   │   ├── timezone.css          # Timezone selector
    │   │   ├── calendar.css          # Calendar + container queries
    │   │   ├── time-slots.css        # Time slots + container queries
    │   │   ├── booking-form.css      # Booking form
    │   │   ├── custom-questions.css  # Custom-questions step
    │   │   ├── overview.css          # Organizer profile
    │   │   ├── confirmation.css      # Confirmation step
    │   │   ├── meeting-pages.css     # Cancel and reschedule pages
    │   │   └── language-switcher.css # Language dropdown
    │   └── theme.css                 # Entry point
    └── rhythm/                        # Rhythm theme (video backgrounds) — coarser split
        ├── modules/
        │   ├── variables.css
        │   ├── base.css              # Root layout + container query context (.scheduling-box)
        │   ├── typography.css
        │   ├── video.css
        │   ├── overview.css
        │   ├── schedule-header.css
        │   ├── booking-form.css
        │   ├── custom-questions.css
        │   ├── confirmation.css
        │   ├── components.css        # All UI controls in one file
        │   ├── language-switcher.css
        │   ├── calendar.css
        │   ├── time-slots.css
        │   └── iframe.css
        └── theme.css
```

The two themes deliberately split their modules at **different granularities** —
there is no fixed module list. Quill breaks UI controls into many small files;
Rhythm consolidates them into `components.css`. Match whichever style suits your
theme; only `variables.css`, `base.css`, and `iframe.css` are universally expected.

### Theme CSS Structure

Each theme's `theme.css` imports the shared entry, then the shared token file right after its own `variables.css`, then its modules:

```css
@import "../../shared/entry.css";        /* Tailwind, shared primitives, variants, @source */

@import "./modules/variables.css";       /* the theme's tokens (MUST come first) */
@import "../../shared/tokens.css";       /* derived tokens (see Token contract) */
@import "./modules/base.css";
/* …the theme's own modules, and shared/components/*.css where the theme uses them */
```

### Token contract

`scheduling/shared/tokens.css` is the contract every theme builds on. Its header lists the four kinds of token (inputs, roles, shared-component tokens, derived tokens). A theme's `variables.css` sets the inputs and defines every role and shared-component token; the derived tokens (`--theme-primary-focus`, `--theme-primary-tint`, `--theme-primary-glow`, `--focus-ring`, `--shadow-{primary,success,danger,warning,info}-*`) are computed with `color-mix()` from the inputs, so a custom palette reaches them automatically. Inputs are only ever overridden on `:root`, never on a wrapper element, or the derived tokens stop following them.

### Intrinsic Responsiveness

Themes use **CSS container queries** and **fluid sizing** instead of viewport breakpoints. Each component file owns its base styles, container queries and component-level iframe overrides in one place; the shared embed shell is in `shared/embed.css`.

**Container query context:** The primary content container (`.scheduling-box` for Rhythm, `.glass-morphism-card` for Quill) has `container-type: inline-size; container-name: scheduling;`. All child components can use `@container scheduling (...)` queries.

**Fluid sizing with `clamp()` and `cqi` units:**
```css
.slide { padding: clamp(0.75rem, 3cqi, 1.5rem); }
.calendar-day { padding: clamp(0.25rem, 1cqi, 0.75rem); }
```

The `cqi` unit resolves against the nearest ancestor with `container-type: inline-size`.

**Fluid grids with `auto-fit`:**
```css
.slot-list__grid { grid-template-columns: repeat(auto-fit, minmax(5rem, 1fr)); }
```

**Container queries for discrete layout switches:**
```css
@container scheduling (min-width: 480px) {
  .calendar-monthly { display: grid; }
  .calendar-weekly { display: none; }
}
```

**What stays as `@media`:**
- Height-based switches (`@media (max-height: ...)`) — container height queries have limited support
- `prefers-reduced-motion` and `print`, co-located in the component they affect
- Elements outside the container query context (e.g. language switcher, which sits outside the primary content container) — these must use viewport `@media` queries since `@container` only matches descendants of the container element

**Browser support:** Safari 16+, Chrome 105+, Firefox 110+.

### Template Guidelines

Templates define structure, CSS defines appearance:
- Use semantic CSS class names describing what the element IS (`.calendar-grid`, `.duration-card`)
- No visual classes in templates (no `rounded-xl`, `shadow-lg`)
- No layout classes in templates (no `flex-row`, `grid-cols-2`)
- No responsive classes in templates (no `sm:`, `md:`, `lg:`)
- Each theme owns its step templates. The shared components listed below have fixed markup: a theme styles their classes in its own CSS and never restructures them.

### Shared Components

The **step layouts** are theme-owned: duration cards, calendar day buttons and the booking form are rendered and styled by each theme. Pieces whose behaviour (accessibility, grouping, events, wording) must not drift between themes are shared components with fixed markup and block-element class names; each theme styles those classes in its own CSS.

Shared across themes:

- **`Shared.Components.CustomAnswers`** (`custom_answers/1`): the confirmation step's "Your answers" list. Classes `custom-answers`, `custom-answers__heading`, `__list`, `__row`, `__label`, `__value`.
- **`Shared.Components.SlotList`** (`slot_list/1`): the schedule step's time-slot panel, with the heading, the screen-reader status line, flat and by-hour grouping, the slot buttons, and the prompt, loading, error and fully-booked states. Classes `slot-list`, `slot-list__heading`, `__body`, `__groups`, `__period`, `__period-label`, `__grid` (`--minutes`), `__slot` (`--selected`, `--hour`, `--expanded`), `__hour-label`, `__hour-count`, `__prompt`, `__loading`, `__error`, `__empty`. Pass `heading_tag`/`period_tag` to fit your page's heading outline, and the `:loading`, `:error` and `:empty` slots only if your theme renders those states with its own markup. Tests select slots by `data-testid="time-slot"` and `"slot-hour"`, never by class.
- **`Shared.Components.TimezonePicker`** (`timezone_picker/1`): the timezone dropdown, search box and options. Classes `tz-picker`, `tz-picker__trigger`, `__panel`, `__search-wrapper`, `__search`, `__options` (which also carries your theme's `scroll-y`), `__option`, `__option-content`, `__option-flag`, `__option-text`, `__option-label`, `__option-offset`. The trigger's visible content is your `:trigger` slot; the screen-reader "Your timezone:" prefix is added for you. Render flags with `FlagHelpers.timezone_flag/1`.
- **`Shared.Components.ThemeShell`** (`theme_shell/1`): the page chrome every wrapper renders, in order: the customisation `<style>` block, your background (`:background` slot), then the theme grid with the preview notice, the language switcher, the step and the configured theme extensions. Your wrapper passes `class`, `grid_class`, `grid_style` and `language_class`, plus its theme's `theme_id` (which the extensions receive), and keeps only its background markup.
- **Data utilities** (`TymeslotWeb.Components.MeetingUtils`): `normalize_slot_list/1`
  and `normalize_slot_time/1` normalise time-slot data.
- **`Shared.Components.MeetingDetails`** (`meeting_detail_rows/1`) — the date/time/
  timezone/organizer row layout used by the cancel and reschedule pages.
- **`Shared.Components.AwaitingPayment`** (`awaiting_payment/1`) — the
  `:awaiting_payment` state placeholder for paid embedded bookings.
- **`Shared.VideoSources`** (`video_sources/1`) — `<source>` elements for video
  backgrounds, used inside each wrapper's `<video>` element.
- **`Shared.CustomQuestions.Inputs.Renderer`** plus the per-type input components —
  the custom-questions field renderers. The theme's `CustomQuestionsComponent`
  supplies the chrome (card, progress indicator) and delegates rendering and events
  to the shared engine.
- **`TymeslotWeb.Components.LanguageSwitcher`** (`language_switcher/1`) — the locale
  dropdown, rendered by `ThemeShell`.

So the dividing line is: **per-step visual layout is theme-owned; cross-cutting
chrome and field rendering is shared.**

When renaming a selector onto a shared class, keep its specificity: a compound rule such as `.time-slot.selected` becomes `.slot-list__slot.slot-list__slot--selected`, not the bare modifier, or an existing `:hover` rule starts winning.

Icon class names stored in the database (e.g., `meeting_type.icon`) must be sanitized before use as CSS class names to prevent CSS injection. Only sanitize the hero-icon path — emoji icons rendered as text content are auto-escaped by Phoenix:

```heex
<%= if String.starts_with?(@icon, "hero-") do %>
  <.icon name={sanitize_css_class(@icon)} class="your-icon-class" />
<% else %>
  <div class="emoji-icon">{@icon}</div>
<% end %>

defp sanitize_css_class(class_name) do
  class_name
  |> String.replace(~r/[^a-zA-Z0-9\-_]/, "")
  |> String.slice(0, 100)
end
```

### iframe.css

The shell rules every theme needs live in `scheduling/shared/embed.css`: body `flow-root` and `max-content` sizing, the page grid (`.booker-page`) sized to content, the footer hidden, the slot scroll region (`.booker-scroll`) released, and full width in the column layout (`.booker-card`). Mark your page grid, cards and slot region with those three classes. Your theme's `iframe.css` then holds only what is specific to it (hiding or repositioning a background, card corners, the language switcher's embedded position).

Size-driven compaction (compact calendar, smaller badges, form re-layout) is handled by container queries in each component file — the same queries that handle narrow viewports.

### Iframe Auto-Resize

When the scheduling page loads inside an iframe, `iframe_embed.js` continuously measures the page's content height and posts it to the parent on a 50ms loop. The parent iframe element grows AND shrinks to match — so themes should let the body flow to its natural content height in embedded mode (`height: max-content`, no `height: 100%` chains). See `shared/embed.css` for the shared rules and `themes/<theme>/modules/iframe.css` for the per-theme overrides.

The embedder can supply `data-initial-height` (px) on the container as a placeholder height shown before the first measurement lands; `data-min-height` is still accepted as a legacy alias. After the first message, the iframe always matches reported content height.

### Creating Theme CSS

1. **Create theme directory**: `assets/css/scheduling/themes/your-theme/`
2. **Create main theme.css** that imports `../../shared/entry.css`, then `./modules/variables.css`, then `../../shared/tokens.css`, then your modules and the `shared/components/*.css` files you use
3. **Create modular CSS files** in a `modules/` subdirectory — each component file is self-contained
4. **Set container query context** on the primary content container (`container-type: inline-size; container-name: scheduling;`)
5. **No external font imports** — use system font stacks or self-hosted fonts only
6. **Everything through tokens, nothing hard-coded**: colours live only in `variables.css`; every other file reads tokens. Run `mix css.check_tokens` (part of `mix precommit`).

**Note**: Theme CSS is completely separate from global app styles.

## Theme Requirements

### Must Have
- Theme module implementing `TymeslotWeb.Themes.Core.Behaviour`
- LiveView module that renders without crashing (using the `SchedulingLive` macro)
- Wrapper component for theme layout
- CSS file in `assets/css/scheduling/themes/your-theme/theme.css`
- `modules/iframe.css` with `[data-embedded]`-scoped iframe shell rules
- Container query context (`container-type: inline-size`) on the primary content container
- The 4 core booking flow states: **overview**, **schedule**, **booking**, **confirmation**
- Handling for the conditional **`:questions`** state (custom-questions step, when the meeting type has custom fields) and the transitional **`:awaiting_payment`** state (paid embedded bookings)
- All 5 step components as LiveComponents (the 4 core steps + `custom_questions_component.ex`)
- Schedule component must include both the weekly strip (mobile) and monthly grid (desktop) with nav buttons wired to `CalendarNavigation` boundary checks
- Meeting action components (reschedule, cancel, cancel_confirmed)

> No per-theme StateMachine module — transitions are owned by the shared
> `StateMachineHelpers`.

### Nice to Have
- Smooth transitions
- Accessibility features

## Using Shared Logic and Helpers

The theme system provides centralized handlers and helpers in `TymeslotWeb.Themes.Shared.*` to ensure consistency and reduce duplication.

> **You normally do not write any of the code in this section by hand.** The
> `use TymeslotWeb.Themes.Shared.SchedulingLive, wrapper: …, steps: …` macro wires up
> `mount/3`, `handle_params/3`, `render/1`, every `handle_info/2` (step components send
> their events to the LiveView as messages), and the language and `navigate_to_step`
> `handle_event/3` clauses for you (see [Common Patterns](#common-patterns)).
> The subsections below document the underlying helpers the macro calls — read them
> to understand what is happening, or when you need to override a specific extension
> point. A real theme's `live.ex` is its `use SchedulingLive, wrapper: …, steps: …`
> line (with the aliases above it) plus optional `handle_theme_event/3` /
> `handle_theme_schedule_event/3` / `handle_theme_info/2` overrides.

### LiveHelpers.Mount, StepEntry and Tracking

The macro's `mount/3` calls `LiveHelpers.Mount.mount_scheduling_view/2`, and its `handle_params/3` calls `LiveHelpers.Mount.handle_scheduling_params/2`; both end by entering the step the route names through `SchedulingFlow`. Entering a step is `SchedulingFlow.handle_state_entry/3`, which uses `LiveHelpers.StepEntry` for the schedule, questions and booking steps. Step components bubble their events as `{:step_event, step, event, data}`; the macro hands them to `SchedulingFlow.handle_step_event/4`, and only a schedule event the flow does not know reaches your `handle_theme_schedule_event/3`.

### EventHandlers

`TymeslotWeb.Themes.Shared.EventHandlers` handles the page-level events outside the booking steps: the language switcher and the timezone search box.

**Key EventHandler Functions**:
- `handle_toggle_language_dropdown/1` - Toggle language selector
- `handle_close_language_dropdown/1` - Close language dropdown
- `handle_change_locale/3` - Change user locale
- `handle_timezone_search/2` - Filter timezone list

### InfoHandlers

`TymeslotWeb.Themes.Shared.InfoHandlers` handles async tasks like availability fetching. The macro's single `handle_info/2` asks `InfoHandlers.route/2` first; a message it returns `:unhandled` for goes to your `handle_theme_info/2`, whose default logs it and ignores it.

**Key InfoHandler Functions**:
- `route/2` - Dispatch a mailbox message to its handler, or return `:unhandled`
- `handle_fetch_available_slots/4` - Fetch available time slots for a date
- `handle_load_slots/2` - Load slots for date selection
- `handle_availability_ok/3` - Process successful availability fetch
- `handle_availability_error/3` - Handle availability fetch errors
- `handle_close_dropdown/1` - Close dropdowns after delay

### SchedulingInit

`TymeslotWeb.Themes.Shared.SchedulingInit` provides two initialization helpers:

**`assign_theme_state/1`** — initializes all scheduling state in one call. The scheduling macro calls it at mount (through `LiveHelpers.Mount`), so a theme does not call it itself.

**`assign_base_state/1`** — lower-level; sets only the core socket fields shared across all flows. Use when you need fine-grained control or are not in a full scheduling context.

**Assigns from `assign_theme_state/1`** (superset of `assign_base_state/1`):
- `:duration`, `:meeting_type` - nil until selected
- `:month_availability_map`, `:availability_status`, `:availability_task`, `:availability_task_ref`
- `:form`, `:touched_fields`, `:validation_errors`, `:saving` - booking form state
- `:client_ip`, `:submission_token`, `:meeting_types`
- Plus all assigns from `assign_base_state/1` below

`:theme_id` is assigned by the dispatcher before the theme mounts.

The calendar window is not set here. `LiveHelpers.Mount` sets `:current_year`, `:current_month`, `:current_week_start` and `:calendar_today` (the date the calendar opened on) with `CalendarHelpers.anchor_on_today/1` once `:user_timezone` is known, so the calendar opens on today in the visitor's timezone. Entering the schedule step reopens it with `CalendarHelpers.anchor_on_selection/1`: on the chosen day's month and week when there is one, whether linked with `?date=YYYY-MM-DD` or chosen on an earlier visit, otherwise on today. A chosen day before today or past the booking window is dropped there, and `NextAvailable` lands the booker on the first free day instead. Anything that positions the calendar on a date uses `CalendarHelpers.anchor_on/2`; do not assign `:current_year`, `:current_month` or `:current_week_start` by hand. A timezone picked in the picker (`CalendarHelpers.follow_timezone_change/1`) moves it only while the booker has neither navigated nor chosen a day, and always refetches the month's availability, which is worked out per day in the visitor's timezone.

**Assigns from `assign_base_state/1`**:
- `:current_state` - Current step in the flow
- `:username_context`, `:organizer_profile`, `:organizer_user_id`
- `:selected_duration`, `:selected_date`, `:selected_time`
- `:available_slots`, `:loading_slots`, `:calendar_error`
- `:timezone_dropdown_open`, `:timezone_search`
- `:reschedule_meeting_uid`, `:is_rescheduling`, `:meeting_uid`
- `:name`, `:email`, `:submitting`, `:submission_processed`

### BookingFlow

`TymeslotWeb.Themes.Shared.BookingFlow` handles form validation and submission; field-touched state lives in `TymeslotWeb.Live.Scheduling.OrganizerHelpers`. `SchedulingFlow` routes the booking step's events to them, so a theme never calls them itself:

```elixir
# In SchedulingFlow
defp booking_event(socket, :validate, data),
  do: BookingFlow.handle_form_validation(socket, data)

defp booking_event(socket, :field_blur, field),
  do: {:noreply, OrganizerHelpers.mark_field_touched(socket, field)}

defp booking_event(socket, :submit, data),
  do: BookingFlow.submit_booking(socket, data, &transition_to/3)
```

**Key BookingFlow Functions**:
- `handle_form_validation/2` - Validate form fields in real-time
- `submit_booking/3` - Submit booking and transition to confirmation
- Both functions handle spam prevention, rate limiting, and error handling automatically

**Per-field inline errors**: Errors are shown per-field using `FormValidationHelpers.field_errors/2`, matching the pattern used by auth and contact forms. Each `.input` in the booking component must pass errors explicitly:

```heex
<.input
  field={f[:name]}
  errors={FormValidationHelpers.field_errors(@validation_errors, :name)}
  ...
/>
```

Errors only appear for fields the user has blurred (`touched_fields` MapSet), and clear automatically when the user corrects the input (validation returns `{:ok, ...}` → `validation_errors` becomes `%{}`).

Each booking input must also include `phx-debounce="blur"` alongside `phx-blur="field_blur"`. The debounce suppresses the `phx-change` event until the field loses focus; the blur event triggers per-field validation. Without the debounce, every keystroke fires a server round-trip:

```heex
<.input
  field={f[:name]}
  errors={FormValidationHelpers.field_errors(@validation_errors, :name)}
  phx-debounce="blur"
  phx-blur="field_blur"
  phx-value-field="name"
  phx-target={@myself}
/>
```

### LocalizationHelpers

Always use `TymeslotWeb.Themes.Shared.LocalizationHelpers` for formatting dates, times, and durations to ensure they respect the user's locale:

```elixir
alias TymeslotWeb.Themes.Shared.LocalizationHelpers

# Result: "Wednesday, 15 March 2024 at 14:30 EST"
LocalizationHelpers.format_booking_datetime(@date, @time, @timezone)

# Result: "30 minutes" or "1 hour"
LocalizationHelpers.format_duration("30min")
```

### PathHandlers

Use `TymeslotWeb.Themes.Shared.PathHandlers` for internal navigation to preserve locale and theme settings:

```elixir
# Build a path that includes ?locale=... and ?theme=...
back_path = PathHandlers.build_path_with_locale(socket, socket.assigns.locale)
```

## CSS Architecture

Themes use a **modular CSS architecture** located in `assets/css/scheduling/`: shared files in `shared/`, each theme in `themes/<theme>/`.

### Shared Files
- `assets/css/scheduling/shared/entry.css` — imported first by every `theme.css`: Tailwind, the primitives below, the LiveView loading variants and the content sources
- `assets/css/scheduling/shared/tokens.css` — the token contract (inputs, roles, shared-component tokens) and the `color-mix()` derived tokens, imported right after the theme's `variables.css`
- `assets/css/scheduling/shared/reset.css` — CSS reset
- `assets/css/scheduling/shared/layout.css` — Border-radius scale, display/flex/grid helpers, status screens
- `assets/css/scheduling/shared/utilities.css` — Shared utility classes
- `assets/css/scheduling/shared/embed.css` — embed shell rules on the booker hook classes
- `assets/css/scheduling/shared/components/*.css` — component styles both themes share (notices, polls, payment pages, booking fields, language switcher, slot list, timezone picker)

Shared component files carry the structure and states; each theme sets their look through the tokens a file lists in its header, defined in the theme's `variables.css`. Where the themes differ by a whole treatment rather than a value, the declarations stay in the theme's own module under the same selector.

### Theme Structure
Each theme has a `theme.css` entry point and a flat `modules/` subdirectory. Each component file owns its base styles, container queries and iframe overrides in one place, with no separate `responsive.css`. The embed shell rules both themes share live in `shared/embed.css`, on the booker hook classes; each theme's `iframe.css` keeps only what differs.

## Theme Customization Spec

Each theme declares what organisers can customise in a spec module implementing `Tymeslot.ThemeCustomizations.Spec`, named by `customization_spec:` in its Catalog entry. The spec is the only place the theme's customisation rules live:

| Callback | Purpose |
|---|---|
| `option_groups/0` | The dashboard panels, e.g. `%{key: :palette, type: :palette}` and `%{key: :background, type: :background, kinds: [:gradient, :color, :image, :video]}` |
| `defaults/0` | The theme's defaults, used when a customisation is first created and when an organiser has none |
| `changeset/2` | All validation, including rejecting an option or background kind the theme does not offer |
| `tokens/2` | Stored settings plus per-page-view overrides to `%Tymeslot.ThemeCustomizations.Tokens{}` |
| `asset_fields/0` | Which settings hold uploaded files, for upload handling and file clean-up |

Build a spec from the shared blocks `Options.Palette` and `Options.Background` rather than restating their rules; `QuillSpec` and `RhythmSpec` are the reference. Colours are validated by `Tymeslot.Utils.Colour.cast_hex/1`: `#RGB` or `#RRGGBB`, stored as lower-case `#rrggbb`.

## Meeting Management Integration

`use TymeslotWeb.Themes.Core.Theme` generates `render_meeting_action/2`, which dispatches each action to the theme's own module:
- `:reschedule` to `Meeting.Reschedule`
- `:cancel` to `Meeting.Cancel`
- `:cancel_confirmed` to `Meeting.CancelConfirmed`

These modules reside in `lib/tymeslot_web/themes/[theme_name]/meeting/`, each with a `render/1`.

## Common Patterns

### Modular LiveView Architecture

Modern themes follow a layered architecture that keeps the LiveView thin and maintainable:

#### 1. **SchedulingLive Macro**

All common LiveView callbacks are provided by the shared macro — no per-theme boilerplate needed:

```elixir
defmodule TymeslotWeb.Themes.Aurora.Scheduling.Live do
  @moduledoc """
  Aurora theme scheduling LiveView: the shared booking flow in Aurora's
  wrapper and step components.
  """

  alias TymeslotWeb.Themes.Aurora.Scheduling.Components.{
    BookingComponent,
    ConfirmationComponent,
    CustomQuestionsComponent,
    OverviewComponent,
    ScheduleComponent
  }

  alias TymeslotWeb.Themes.Aurora.Scheduling.Wrapper

  use TymeslotWeb.Themes.Shared.SchedulingLive,
    wrapper: &Wrapper.aurora_wrapper/1,
    steps: %{
      overview: OverviewComponent,
      schedule: ScheduleComponent,
      questions: CustomQuestionsComponent,
      booking: BookingComponent,
      confirmation: ConfirmationComponent
    }
end
```

The macro generates `mount/3`, `handle_params/3`, `handle_info/2`, `handle_event/3` and `render/1`. `render/1` puts the current step's component inside your wrapper, and also handles the organiser-not-ready message, the `:awaiting_payment` screen and an unknown state. The aliases must come before `use`.

State machine logic (initial state, transition validation, navigation guards) lives in the shared `StateMachineHelpers` module — no per-theme StateMachine module is required.

#### 2. **Legacy: Per-Theme StateMachine Module**

> **Deprecated** — do not create new per-theme `state_machine.ex` files. The shared `StateMachineHelpers` covers all standard transitions. If you need custom transition validation, change `StateMachineHelpers`, which every theme shares, instead.

For historical reference, the shared module handles:

```elixir
defmodule TymeslotWeb.Themes.Aurora.Scheduling.StateMachine do
  @moduledoc """
  State machine for Aurora theme scheduling flow.
  """

  @doc "Determines initial state from Phoenix live_action"
  def determine_initial_state(live_action) do
    case live_action do
      :index -> :overview
      :overview -> :overview
      :schedule -> :schedule
      :booking -> :booking
      :confirmation -> :confirmation
      _other -> :overview
    end
  end

  @doc "Validates state transitions"
  def validate_state_transition(socket, current_state, next_state) do
    case {current_state, next_state} do
      {:overview, :schedule} -> validate_overview_complete(socket)
      {:schedule, :booking} -> validate_schedule_complete(socket)
      {:booking, :confirmation} -> {:ok, socket}
      _ -> {:error, "Invalid state transition"}
    end
  end

  @doc "Checks if navigation to a step is allowed"
  def can_navigate_to_step?(socket, target_state, states) do
    # Only allow navigation to previous or current steps; `states` is
    # `states_for(meeting_type)`, so step numbers follow the meeting type's flow
    with %{step: current_step} <- states[socket.assigns[:current_state]],
         %{step: target_step} <- states[target_state] do
      target_step <= current_step
    else
      _other -> false
    end
  end

  defp validate_overview_complete(socket) do
    if socket.assigns[:duration] && socket.assigns[:meeting_type] do
      {:ok, socket}
    else
      {:error, "Please select a meeting duration"}
    end
  end

  defp validate_schedule_complete(socket) do
    cond do
      not socket.assigns[:selected_date] ->
        {:error, "Please select a date"}
      not socket.assigns[:selected_time] ->
        {:error, "Please select a time"}
      true ->
        {:ok, socket}
    end
  end

  defp get_step_number(state) do
    case state do
      :overview -> 1
      :schedule -> 2
      :booking -> 3
      :confirmation -> 4
      _ -> 0
    end
  end
end
```

#### 3. **Wrapper Component**

The wrapper provides the theme's background and class names; the shared `ThemeShell` renders the rest of the page chrome (customisation styles, preview notice, language switcher, theme extensions) around them:

```elixir
defmodule TymeslotWeb.Themes.Aurora.Scheduling.Wrapper do
  use Phoenix.Component

  alias Tymeslot.Themes.Catalog
  alias TymeslotWeb.Themes.Shared.Components.ThemeShell

  import TymeslotWeb.Themes.Shared.Customization.Helpers
  import TymeslotWeb.Themes.Shared.VideoSources, only: [video_sources: 1]

  attr :theme_customization, :map, default: nil
  attr :custom_css, :string, default: nil
  attr :locale, :string, default: nil
  attr :current_state, :atom, default: nil
  attr :language_dropdown_open, :boolean, default: nil
  attr :organizer_user_id, :integer, default: nil
  attr :should_show_branding, :boolean, default: false
  attr :show_language_switcher, :boolean, default: nil
  attr :owner_preview, :boolean, default: false
  attr :demo_mode, :boolean
  slot :inner_block, required: true

  def aurora_wrapper(assigns) do
    # Derives @has_video_background, @video_poster, @show_language_switcher
    assigns = assigns |> prepare_wrapper_assigns() |> assign(:theme_id, theme_id())

    ~H"""
    <ThemeShell.theme_shell
      class="aurora-theme-wrapper theme-3"
      grid_class="aurora-content theme-grid"
      grid_style={
        if @theme_customization && !@has_video_background,
          do: get_background_style(@theme_customization)
      }
      language_class="aurora-language-switcher"
      theme_id={@theme_id}
      custom_css={@custom_css}
      locale={@locale}
      language_dropdown_open={@language_dropdown_open}
      show_language_switcher={@show_language_switcher}
      owner_preview={@owner_preview}
      organizer_user_id={@organizer_user_id}
      should_show_branding={@should_show_branding}
      {Map.take(assigns, [:demo_mode])}
    >
      <:background :if={@has_video_background}>
        <div class="video-background">
          <video autoplay muted loop playsinline preload="metadata" poster={@video_poster}>
            <.video_sources theme_customization={@theme_customization} />
          </video>
        </div>
      </:background>
      {render_slot(@inner_block)}
    </ThemeShell.theme_shell>
    """
  end

  defp theme_id do
    {:ok, id} = Catalog.key_to_id(:aurora)
    id
  end
end
```

Notes on the real pattern (matching Quill and Rhythm):
- `ThemeShell` renders the language switcher (`TymeslotWeb.Components.LanguageSwitcher`),
  which takes no theme argument: it emits the theme-neutral classes `lang-switcher`,
  `lang-switcher__button`, `__panel`, `__item` and `__item--active`, which the theme's
  own CSS styles. Your wrapper only names the class of its container (`language_class`).
- `custom_css` arrives as a ready-to-emit assign; `ThemeShell` writes it into a
  `:root { … }` `<style>` block. Do not generate it in the wrapper.
- `organizer_user_id` is an **integer**.
- `ThemeShell` renders the theme extensions (`Layouts.render_theme_extensions/1`) in the
  grid's footer row, handing them `theme_id`, `organizer_user_id`,
  `should_show_branding`, and `demo_mode` when the page assigned one. Do not hand-roll
  a "Powered by Tymeslot" footer.
- Pass `demo_mode` on with `{Map.take(assigns, [:demo_mode])}` rather than as
  `demo_mode={@demo_mode}`, so the extensions see it only when the page set it.

#### 4. **Step Components**

Each step is a separate LiveComponent:

```elixir
defmodule TymeslotWeb.Themes.Aurora.Scheduling.Components.OverviewComponent do
  use TymeslotWeb, :live_component

  alias TymeslotWeb.Themes.Shared.StepEvents

  @impl Phoenix.LiveComponent
  defdelegate update(assigns, socket), to: StepEvents

  @impl Phoenix.LiveComponent
  defdelegate handle_event(event, params, socket), to: StepEvents

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div class="overview-step">
      <h1>Select Meeting Duration</h1>
      <div class="meeting-types">
        <%= for mt <- @meeting_types do %>
          <button
            phx-click="select_duration"
            phx-value-duration={mt.duration}
            phx-target={@myself}
            class={duration_button_class(mt.duration, @duration)}
          >
            <%= format_duration(mt.duration) %>
          </button>
        <% end %>
      </div>
    </div>
    """
  end
end
```

#### 5. **Shared Modules**

Leverage shared modules to avoid duplication:

- **SchedulingLive** (macro): All LiveView callbacks and `render/1` — `use TymeslotWeb.Themes.Shared.SchedulingLive, wrapper: …, steps: …`
- **SchedulingInit**: Base state initialization
- **BookingFlow**: Form validation and submission
- **SchedulingFlow**: Step events, transitions and step entry
- **EventHandlers**: Language switcher and timezone search
- **InfoHandlers**: Async task handling (availability fetching)
- **LocalizationHelpers**: Date/time formatting
- **PathHandlers**: Navigation with locale preservation
- **VideoSources**: `<.video_sources theme_customization={...} />` — video `<source>` elements for wrapper components
- **MeetingDetails**: `<.meeting_detail_rows date={...} time={...} timezone={...} organizer_name={...} />` — shared cancel/reschedule row layout

#### 6. **Event Communication Pattern**

Templates send one of the canonical events (listed in `Shared.StepEvents`'s moduledoc) with `phx-target={@myself}`; the component delegates `handle_event/3` to `Shared.StepEvents`, which relays `{:step_event, step, event, data}` to the LiveView, where `SchedulingFlow.handle_step_event/4` handles it. A theme never writes its own relay; an event name outside the canonical set is ignored.

### Theme Template Rendering

You do not write `render/1`: `use SchedulingLive, wrapper:, steps:` generates it
through `Shared.SchedulingPage`. Your wrapper receives `custom_css`,
`theme_customization`, `locale`, `language_dropdown_open`, `current_state`,
`organizer_user_id`, `owner_preview`, `should_show_branding`, `demo_mode` when the
LiveView assigned one, and an inner block;
`steps:` must name a LiveComponent for each of `:overview`, `:schedule`, `:questions`,
`:booking` and `:confirmation`, and no other key, which compilation checks.

## Theme Customization System

### Background Options

Themes can offer users four types of backgrounds:

1. **Gradients** - CSS gradients defined in `Tymeslot.ThemeCustomizations.Presets.get_gradient_presets/0`
2. **Solid Colors** - User-selected hex colors
3. **Preset Images/Videos** - Pre-defined options stored in `/priv/static/`
4. **Custom Uploads** - User-uploaded images or videos

### Preset Assets Structure

Preset assets are organized in the static directory:

```
priv/static/
├── images/ui/backgrounds/       # Preset background images
│   ├── artistic-studio.webp
│   ├── ocean-sunset.webp
│   └── ...
├── videos/backgrounds/          # Preset background videos
│   ├── blue-wave-desktop.webm   # Desktop WebM
│   ├── blue-wave-desktop.mp4    # Desktop MP4
│   ├── blue-wave-mobile.mp4     # Mobile optimized
│   ├── blue-wave-low.mp4        # Low bandwidth
│   └── ...
└── images/ui/posters/           # Video posters (thumbnails)
    ├── blue-wave-thumbnail.jpg
    └── rhythm-background-poster.webp
```

### Defining Presets

Presets are defined in `lib/tymeslot/theme_customizations/presets.ex`.

**Available Video Presets**:
- `"preset:rhythm-default"`
- `"preset:blue-wave"`
- `"preset:dancing-girl"`
- `"preset:leaves"`
- `"preset:light-green"`
- `"preset:space"`

**Available Image Presets**:
- `"preset:artistic-studio"`
- `"preset:ocean-sunset"`
- `"preset:elegant-still-life"`

## Advanced Video Features

### Video Container Rendering

For themes with video backgrounds, use the `VideoSources` shared component to render `<source>` elements inside your video container. Import it in your wrapper:

```elixir
import TymeslotWeb.Themes.Shared.VideoSources, only: [video_sources: 1]
```

Then use it in your wrapper template:

```heex
<div class="your-video-container">
  <video autoplay muted loop playsinline>
    <.video_sources theme_customization={@theme_customization} />
  </video>
</div>
```

The component handles both user-uploaded videos and preset videos automatically, selecting the correct source paths and falling back to nothing if no video is configured.

To build the `<source>` markup yourself, rather than letting `<.video_sources />` do it, call `TymeslotWeb.Themes.Shared.Customization.Video` directly:

```elixir
alias TymeslotWeb.Themes.Shared.Customization.Video

# In your theme wrapper, for a bundled preset background
<video class="video-container" autoplay muted loop playsinline>
  {Phoenix.HTML.raw(Video.render_preset_video_sources("blue-wave-desktop.mp4"))}
</video>
```

Use `render_upload_video_sources/1` instead when the background is an uploaded file rather than a bundled preset.

### Multi-Quality Video System

The video system automatically selects the best quality based on the filename suffix:
- `-desktop.webm`: Best quality for modern browsers
- `-desktop.mp4`: Standard desktop quality
- `-mobile.mp4`: Optimized for tablets and phones
- `-low.mp4`: Low bandwidth fallback

## Multi-Lingual Support

### Overview

Tymeslot booking pages support internationalization (i18n) with automatic browser language detection.

**Supported Languages:**
- 🇬🇧 English (`en`)
- 🇩🇪 German (`de`)
- 🇺🇦 Ukrainian (`uk`)
- 🇫🇷 French (`fr`)
- 🇮🇹 Italian (`it`)
- 🇨🇿 Czech (`cs`)

### Language Switcher Integration

`ThemeShell` renders the language switcher for every theme's wrapper, inside a container carrying the wrapper's `language_class`, and only when the page passes both `locale` and `language_dropdown_open`. `show_language_switcher` (derived by `prepare_wrapper_assigns/1`) adds `visible` or `hidden` to that container.

### Path Generation & Localization

Always use `PathHandlers` for internal links to preserve the user's locale:

```elixir
# Path with current locale and theme preserved
path = PathHandlers.build_path_with_locale(socket, @locale)
```

Use `LocalizationHelpers` for all date and time formatting:

```elixir
# Localized: "Wednesday, 15 March 2024"
LocalizationHelpers.format_date(@selected_date)
```


## Development Workflow

### Step-by-Step Implementation

1. **Copy an existing theme** (Quill or Rhythm) as a starting point
2. **Register the theme** — add facts to `Tymeslot.Themes.Catalog` and bindings to `TymeslotWeb.Themes.Core.Registry`
3. **Rename files and modules** to match your theme name
4. **Create `live.ex`** with `use TymeslotWeb.Themes.Shared.SchedulingLive, wrapper: …, steps: …` — no per-theme StateMachine needed
5. **Update the Wrapper** with your theme's visual design; use `<.video_sources .../>` for video backgrounds
6. **Modify step components** (overview, schedule, custom_questions, booking, confirmation)
7. **Create CSS modules** in `assets/css/scheduling/themes/your-theme/`; import `../../shared/entry.css` first in your theme.css, then `./modules/variables.css` and `../../shared/tokens.css`
8. **Implement meeting actions** (reschedule, cancel, cancel_confirmed); use `<.meeting_detail_rows .../>` for the detail layout
9. **Test with production checklist**

### What to Copy vs. What to Customize

**Don't copy at all** — the shared macro provides this automatically:
- `use TymeslotWeb.Themes.Shared.SchedulingLive, wrapper: …, steps: …` replaces all LiveView event handlers, state init, `render/1`, and shared module wiring
- No per-theme `state_machine.ex` — `StateMachineHelpers` is shared

**Customize** (theme-specific):
- `wrapper:` and `steps:` passed to `use SchedulingLive`
- `handle_theme_event/3` override — only for events of your own; step navigation (`navigate_to_step`) and every step event are handled before it and cannot be overridden
- Wrapper component layout and design
- Step component templates and styles
- CSS modules and variables
- Meeting action component designs (use `<.meeting_detail_rows .../>` for the rows)

**Do not re-derive in your wrapper or step components** (already in socket assigns):
- `organizer_user_id` — set during mount by `SchedulingInit.assign_base_state/1` via `Scheduling.Helpers`. Do not extract it from `organizer_profile` in the wrapper or a step component; read `@organizer_user_id` directly.

### Testing Your Theme

Run the production checklist to validate your theme:

```bash
# Test all registered themes
mix test test/tymeslot_web/live/themes/theme_production_checklist_test.exs

# Or test a specific theme
mix test test/tymeslot_web/live/themes/theme_production_checklist_test.exs -t theme_id:3
```

The checklist automatically verifies:
- Theme renders without crashing
- All meeting types display correctly
- Edge cases work (no meetings, long names, etc.)
- Basic mobile responsiveness
- Acceptable load times
- State transitions function properly

### Debugging Tips

**Common Issues**:

1. **Component not found**: Check aliases in theme module match component names
2. **CSS not loading**: Verify `theme.css` imports all modules in correct order
3. **State transitions broken**: Check `StateMachineHelpers.validate_state_transition/3`
4. **`:questions` step skipped or stuck**: Confirm the meeting type actually has custom fields — `StateMachineHelpers.states_for/1` only inserts `:questions` when `custom_fields` is non-empty
5. **Availability not loading**: Ensure InfoHandlers are implemented
6. **Form submission fails**: Check BookingFlow integration

**Debug helpers**:

```elixir
# In LiveView mount, render, or handle_info
require Logger
Logger.debug("Socket assigns: #{inspect(socket.assigns)}")
```

## Best Practices

### Do's

✅ **Use the `SchedulingLive` macro** - It provides all common LiveView callbacks
✅ **Use shared modules** - StateMachineHelpers, EventHandlers, InfoHandlers, BookingFlow
✅ **Implement all required callbacks** - the compiler checks the behaviour; `theme_contract_test.exs` checks what each callback renders
✅ **Keep LiveView thin** - `live.ex` holds the `use SchedulingLive` line and, at most, your own event hooks; the page lives in the wrapper and step components
✅ **Use LocalizationHelpers** - For all date/time formatting
✅ **Test with production checklist** - Automated validation catches issues early
✅ **Copy existing themes** - Rhythm and Quill are proven implementations

### Don'ts

❌ **Don't hardcode dates/times** - Always use LocalizationHelpers
❌ **Don't create a per-theme StateMachine** - `StateMachineHelpers` owns transitions; change `StateMachineHelpers`, which every theme shares, for custom logic
❌ **Don't duplicate shared logic** - Use the Shared.* modules
❌ **Don't mix theme and app styles** - Keep theme CSS isolated
❌ **Don't forget meeting actions** - Reschedule, cancel, cancel_confirmed required
❌ **Don't over-engineer** - Start simple, add complexity only when needed

## Summary Checklist

Before considering your theme complete:

- [ ] Theme facts added to `Catalog`, bindings added to `Registry`
- [ ] Entry added to `TymeslotWeb.ThemeTestMatrix` (`test/support/theme_test_matrix.ex`)
- [ ] Theme module implements all behaviour callbacks
- [ ] LiveView uses the `SchedulingLive` macro (no per-theme StateMachine)
- [ ] Wrapper component provides theme layout
- [ ] All 5 step components implemented (overview, schedule, custom_questions, booking, confirmation)
- [ ] `live.ex` passes `wrapper:` and a `steps:` map with all five steps to `use SchedulingLive`
- [ ] Schedule component has weekly strip (mobile) + monthly grid (desktop) with `CalendarNavigation` boundary checks on all nav buttons
- [ ] All 3 meeting action components implemented
- [ ] CSS theme.css imports all required modules
- [ ] `modules/iframe.css` created with `[data-embedded]`-scoped iframe shell rules
- [ ] Container query context set on primary content container
- [ ] No responsive Tailwind classes (`sm:`, `md:`, `lg:`) in templates
- [ ] No external font imports (use system fonts or self-hosted)
- [ ] Production checklist tests pass
- [ ] Intrinsic responsiveness works at all sizes (no viewport breakpoints)
- [ ] Localization works for all supported languages
- [ ] Video/image backgrounds work (if supported)
- [ ] Theme customization renders correctly
- [ ] Embedded mode tested — iframe grows and shrinks with content; no internal scrollbar in unconstrained inline embeds