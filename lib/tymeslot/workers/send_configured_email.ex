defmodule Tymeslot.Workers.SendConfiguredEmail do
  @moduledoc """
  Sends an email built by a template the deployment configures (the
  `:refund_processed_template` and friends a payment webhook names), from a
  job, so a mail outage delays it rather than losing it.

  The webhook enqueues and returns; this job builds the email when it runs,
  for the user it names (loaded fresh, with their profile) or for an address,
  and delivers it through `TransactionalEmailDelivery`: an open mail circuit
  snoozes the job without spending an attempt, a permanently rejected
  address discards it, and any other failure retries. The send is claimed,
  so a job the lifeline rescues after it went out does not send it again.

  The template's arguments travel in the job encoded with
  `:erlang.term_to_binary/1` (and read back with
  `Plug.Crypto.non_executable_binary_to_term/2`, which refuses new atoms and
  functions), since they can hold dates; callers pass plain maps and values,
  never a whole struct.
  """

  use Oban.Worker, queue: :emails, max_attempts: 10, priority: 1

  require Logger

  alias Plug.Crypto
  alias Tymeslot.Auth
  alias Tymeslot.Infrastructure.ExpectedJobOutcome
  alias Tymeslot.Workers.DeliveryClaims
  alias Tymeslot.Workers.TransactionalEmailDelivery

  @behaviour ExpectedJobOutcome

  @not_configured "template not configured"
  @user_gone "user not found"

  @type recipient :: {:user, pos_integer()} | {:address, String.t()}

  @impl ExpectedJobOutcome
  def expected_outcome?(reason),
    do:
      reason in [@not_configured, @user_gone] or
        TransactionalEmailDelivery.recipient_rejected?(reason)

  @doc """
  Enqueues the email `template_key`'s module builds with `template_fun`,
  called with the recipient (the user, or the address) followed by
  `template_args`. Does nothing for a template the deployment has not
  configured (a self-hosted install has none of them).
  """
  @spec enqueue(atom(), atom(), recipient(), list()) :: :ok | {:error, term()}
  def enqueue(template_key, template_fun, recipient, template_args)
      when is_atom(template_key) and is_atom(template_fun) and is_list(template_args) do
    if configured_template(template_key) do
      job =
        new(%{
          "template_key" => Atom.to_string(template_key),
          "template_fun" => Atom.to_string(template_fun),
          "recipient" => encode_recipient(recipient),
          "template_args" => template_args |> :erlang.term_to_binary() |> Base.encode64()
        })

      case Oban.insert(job) do
        {:ok, _job} -> :ok
        {:error, _reason} = error -> error
      end
    else
      Logger.debug("Email template not configured, nothing sent", template: template_key)
      :ok
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: args} = job) do
    %{"template_key" => key, "template_fun" => fun, "recipient" => recipient} = args
    template_key = String.to_existing_atom(key)

    with {:ok, template} <- fetch_template(template_key),
         {:ok, first_arg} <- resolve_recipient(recipient) do
      template_args =
        args["template_args"]
        |> Base.decode64!()
        |> Crypto.non_executable_binary_to_term([:safe])

      template_fun = String.to_existing_atom(fun)

      DeliveryClaims.once(job, "email", fn ->
        template
        |> apply(template_fun, [first_arg | template_args])
        |> TransactionalEmailDelivery.deliver(job, "Configured email delivery failed",
          template: template_key
        )
      end)
    end
  end

  defp configured_template(key) do
    template = Application.get_env(:tymeslot, key)
    if template && Code.ensure_loaded?(template), do: template
  end

  defp fetch_template(key) do
    case configured_template(key) do
      nil -> {:discard, @not_configured}
      template -> {:ok, template}
    end
  end

  # Every template reached from here greets a user by name, and
  # `Profiles.user_display_name/1` raises rather than guessing when the
  # profile is unloaded, so the user comes with it.
  defp resolve_recipient(%{"user_id" => user_id}) do
    case Auth.get_user_with_profile(user_id) do
      {:ok, user} -> {:ok, user}
      {:error, :not_found} -> {:discard, @user_gone}
    end
  end

  defp resolve_recipient(%{"address" => address}), do: {:ok, address}

  defp encode_recipient({:user, user_id}), do: %{"user_id" => user_id}
  defp encode_recipient({:address, address}), do: %{"address" => address}
end
