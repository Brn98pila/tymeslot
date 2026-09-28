defmodule TymeslotWeb.Themes.Shared.Components.CustomAnswers do
  @moduledoc """
  The confirmation step's "Your answers" list: each custom question from the
  booking's snapshot with the guest's answer, rendered through
  `Tymeslot.CustomFields.AnswerRenderer`.

  Fixed markup with `custom-answers__*` class names; each theme styles them in
  its own CSS. Renders nothing when the meeting type asked no questions.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.CustomFields.AnswerRenderer

  attr :snapshot, :list, default: nil, doc: "the booking's `custom_fields_snapshot`"
  attr :answers, :map, default: nil, doc: "answers keyed by question id"

  @spec custom_answers(map()) :: Phoenix.LiveView.Rendered.t()
  def custom_answers(assigns) do
    ~H"""
    <section :if={@snapshot not in [nil, []]} class="custom-answers">
      <h3 class="custom-answers__heading">{dgettext("booking", "Your answers")}</h3>
      <dl class="custom-answers__list">
        <div :for={question <- @snapshot} class="custom-answers__row">
          <dt class="custom-answers__label">{question["label"]}</dt>
          <dd class="custom-answers__value">
            {AnswerRenderer.render(question, @answers[question["id"]])}
          </dd>
        </div>
      </dl>
    </section>
    """
  end
end
