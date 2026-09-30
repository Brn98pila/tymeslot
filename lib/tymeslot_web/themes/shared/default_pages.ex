defmodule TymeslotWeb.Themes.Shared.DefaultPages do
  @moduledoc """
  The meeting, poll and payment pages of a theme that declares
  `use TymeslotWeb.Themes.Core.Theme, page_shell: &MyShell.page_shell/1`:
  each page's shared body (`MeetingPageBodies`, `PollVotingComponents`,
  `PaymentReturnComponents`) inside the theme's shell.

  The shell is a function component. It receives `page` (`:reschedule`,
  `:cancel`, `:cancel_confirmed`, `:poll`, `:payment_processing`,
  `:payment_cancelled`), the page's `theme_tokens`, `locale` and
  `language_dropdown_open` (all `nil` on the payment pages), and the body
  as its inner block; it draws the theme's wrapper and card (with the
  `booker-card` hook class) around it.

  Every body sits in `<div class="manage-page manage-page--<page>"
  data-testid="<theme key>-<page>">`, so the payment pages carry the
  `<key>-payment-processing` and `<key>-payment-cancelled` ids the payment
  return suite tells themes apart by.
  """

  use Phoenix.Component

  alias Tymeslot.Themes.Catalog
  alias TymeslotWeb.Themes.Shared.Components.MeetingPageBodies
  alias TymeslotWeb.Themes.Shared.{PaymentReturnComponents, PollVotingComponents}

  @type shell :: (map() -> Phoenix.LiveView.Rendered.t())

  @meeting_actions [:reschedule, :cancel, :cancel_confirmed]

  @doc "A meeting page (`render_meeting_action/2`); any other action raises."
  @spec meeting_action(map(), atom(), shell()) :: Phoenix.LiveView.Rendered.t()
  def meeting_action(assigns, action, shell) when action in @meeting_actions,
    do: page(assigns, action, shell)

  def meeting_action(_assigns, action, _shell), do: raise("Unsupported meeting action: #{action}")

  @doc "The poll voting page (`render_poll_action/1`)."
  @spec poll(map(), shell()) :: Phoenix.LiveView.Rendered.t()
  def poll(assigns, shell), do: page(assigns, :poll, shell)

  @doc "A payment return page (`render_payment_page/2`)."
  @spec payment(map(), :processing | :cancelled, shell()) :: Phoenix.LiveView.Rendered.t()
  def payment(assigns, :processing, shell), do: page(assigns, :payment_processing, shell)
  def payment(assigns, :cancelled, shell), do: page(assigns, :payment_cancelled, shell)

  # The bodies are called as functions, not as `<.component>`, so their attr
  # defaults do not apply: the optional keys any body reads are set here.
  defp page(assigns, page, shell) do
    slug = page |> Atom.to_string() |> String.replace("_", "-")

    # A page is also rendered from a plain map (the theme contract tests do),
    # which carries no change tracking: nil tracks nothing, as a first render.
    assigns =
      assigns
      |> Map.put_new(:__changed__, nil)
      |> assign(
        page: page,
        page_shell: shell,
        page_testid: testid(assigns[:theme_id], slug),
        page_class: "manage-page--" <> slug,
        loading: assigns[:loading] || false,
        meeting_kept: assigns[:meeting_kept] || false,
        meeting_uid: assigns[:meeting_uid],
        organizer_profile: assigns[:organizer_profile],
        participant: assigns[:participant]
      )

    ~H"""
    <.shell
      page_shell={@page_shell}
      page={@page}
      theme_tokens={assigns[:theme_tokens]}
      locale={assigns[:locale]}
      language_dropdown_open={assigns[:language_dropdown_open]}
    >
      <div class={["manage-page", @page_class]} data-testid={@page_testid}>
        {body(assigns)}
      </div>
    </.shell>
    """
  end

  # The shell is chosen at runtime (as `SchedulingPage` applies a theme's
  # wrapper), so it is called directly with the assigns it documents.
  defp shell(assigns) do
    {shell, assigns} = Map.pop(assigns, :page_shell)
    shell.(assigns)
  end

  defp body(%{page: :reschedule} = assigns), do: MeetingPageBodies.reschedule(assigns)
  defp body(%{page: :cancel} = assigns), do: MeetingPageBodies.cancel(assigns)
  defp body(%{page: :cancel_confirmed} = assigns), do: MeetingPageBodies.cancel_confirmed(assigns)

  defp body(%{page: :poll} = assigns) do
    ~H"""
    <PollVotingComponents.poll_content
      poll={@poll}
      tallies={@tallies}
      voting_open={@voting_open}
      participant={@participant}
    />
    """
  end

  defp body(%{page: :payment_processing} = assigns) do
    ~H"""
    <PaymentReturnComponents.processing_body
      loading={@loading}
      payment={@payment}
      meeting={@meeting}
      rebook_path={@rebook_path}
    />
    """
  end

  defp body(%{page: :payment_cancelled} = assigns) do
    ~H"""
    <PaymentReturnComponents.cancelled_body rebook_path={@rebook_path} />
    """
  end

  defp testid(theme_id, slug) when is_binary(theme_id) do
    case Catalog.id_to_key(theme_id) do
      {:ok, key} -> "#{key}-#{slug}"
      {:error, _reason} -> nil
    end
  end

  defp testid(_no_theme, _slug), do: nil
end
