defmodule Tymeslot.Security.CredentialReencryption.PlainOnlyReport do
  @moduledoc """
  Read-only pre-check for dropping the plain-text copies of secrets that
  moved to encrypted (or hashed) columns.

  The plain columns stay so that an image rolled back across the encryption
  release still finds its values, and that image writes only them. Before the
  columns are emptied or dropped, every row that still holds a plain value is
  classified against its encrypted counterpart:

    * `:plain_only`: the counterpart is empty. The row was written by a
      rolled-back image and never encrypted; dropping the column destroys a
      live secret. Backfill the counterpart from the plain value first (and,
      for the token columns, its `*_hash` lookup column).
    * `:differing`: both are set and disagree. For every column except the
      Telegram link token this means a rolled-back image changed the value
      after the upgrade, so the encrypted copy is stale and the plain one is
      current: re-encrypt from the plain value first. Telegram link tokens
      are reissued by the current release without clearing the plain copy,
      so there a difference is expected; those tokens expire and are never
      restored.
    * `:unreadable`: the counterpart is set but no configured key opens it,
      so the two cannot be compared. Resolve the keys first.
    * `:matching`: the counterpart holds the same value; the plain copy is
      safe to empty.

  `clear?` is true only when no row is `:plain_only`, `:differing` or
  `:unreadable`. The report holds counts and up to 10 sample row ids per
  category, never a value.
  """

  alias Ecto.UUID
  alias Tymeslot.Security.CredentialReencryptionQueries, as: Queries
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Security.Token

  # The plain columns the expand migrations of the encryption release kept,
  # and what replaced each. A fixed set: nothing adds plain copies any more,
  # and the contract migration removes them all.
  @plain_copies [
    {"webhooks", :url, {:encrypted, :url_encrypted}},
    {"video_integrations", :custom_meeting_url, {:encrypted, :custom_meeting_url_encrypted}},
    {"calendar_integrations", :google_channel_secret,
     {:encrypted, :google_channel_secret_encrypted}},
    {"calendar_integrations", :graph_client_state, {:encrypted, :graph_client_state_encrypted}},
    {"telegram_integrations", :link_token, {:hash, :link_token_hash}},
    {"polls", :token, {:encrypted, :token_encrypted}},
    {"poll_participants", :token, {:encrypted, :token_encrypted}},
    {"meeting_guests", :rsvp_token, {:encrypted, :rsvp_token_encrypted}},
    {"profiles", :freebusy_token, {:encrypted, :freebusy_token_encrypted}}
  ]

  @categories [:plain_only, :differing, :unreadable, :matching]
  @blocking [:plain_only, :differing, :unreadable]
  @sample_size 10
  @batch_size 200

  @type category :: :plain_only | :differing | :unreadable | :matching
  @type column_report :: %{
          required(category()) => non_neg_integer(),
          required(:sample_ids) => %{optional(category()) => [integer() | String.t()]}
        }
  @type report :: %{columns: %{String.t() => column_report()}, clear?: boolean()}

  @doc "The plain columns checked, with the counterpart that replaced each."
  @spec plain_copies() :: [{String.t(), atom(), {:encrypted | :hash, atom()}}]
  def plain_copies, do: @plain_copies

  @doc "Classifies every row still holding a plain value. Read-only."
  @spec run() :: report()
  def run do
    columns =
      Map.new(@plain_copies, fn {table, plain, counterpart} ->
        {"#{table}.#{plain}", check_column(table, plain, counterpart)}
      end)

    clear? =
      Enum.all?(Map.values(columns), fn counts -> Enum.all?(@blocking, &(counts[&1] == 0)) end)

    %{columns: columns, clear?: clear?}
  end

  defp check_column(table, plain, {_kind, counterpart_column} = counterpart) do
    empty = Map.put(Map.new(@categories, &{&1, 0}), :sample_ids, %{})

    table
    |> Queries.stream_rows([plain, counterpart_column], @batch_size, present: plain)
    |> Enum.reduce(empty, fn row, acc ->
      category =
        classify(Map.fetch!(row, plain), counterpart, Map.fetch!(row, counterpart_column))

      record(acc, category, row.id)
    end)
  end

  defp classify(_plain, _counterpart, nil), do: :plain_only

  defp classify(plain, {:hash, _column}, hash) do
    if Token.hash_token(plain) == hash, do: :matching, else: :differing
  end

  defp classify(plain, {:encrypted, _column}, ciphertext) do
    case Encryption.decrypt_with_status(ciphertext) do
      {:ok, ^plain} -> :matching
      {:ok, nil} -> :plain_only
      {:ok, _other} -> :differing
      {:error, :requires_reencryption} -> :unreadable
    end
  end

  defp record(acc, category, id) do
    acc
    |> Map.update!(category, &(&1 + 1))
    |> sample(category, display_id(id))
  end

  defp sample(acc, :matching, _id), do: acc

  defp sample(%{sample_ids: samples} = acc, category, id) do
    ids = Map.get(samples, category, [])

    if length(ids) < @sample_size,
      do: %{acc | sample_ids: Map.put(samples, category, ids ++ [id])},
      else: acc
  end

  # UUID keys come back from a schemaless query as their raw 16 bytes.
  defp display_id(<<_uuid::binary-size(16)>> = raw), do: UUID.load!(raw)
  defp display_id(id), do: id
end
