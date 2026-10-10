defmodule Tymeslot.Security.CredentialReencryption.PlainOnlyReportTest do
  use Tymeslot.DataCase, async: true

  @moduletag :security

  alias Ecto.UUID
  alias Tymeslot.Security.CredentialReencryption
  alias Tymeslot.Security.CredentialReencryption.PlainOnlyReport
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Security.Token

  test "is clear when no row holds a plain copy" do
    insert(:webhook, url: "https://hooks.example.com/encrypted-only")

    assert %{clear?: true, columns: columns} = CredentialReencryption.plain_only_report()
    assert columns["webhooks.url"].matching == 0
  end

  test "classifies each plain webhook URL against its encrypted copy" do
    webhook_with(
      plain: "https://hooks.example.com/same",
      encrypted: "https://hooks.example.com/same"
    )

    plain_only = webhook_with(plain: "https://hooks.example.com/rollback", encrypted: nil)

    differing =
      webhook_with(
        plain: "https://hooks.example.com/edited",
        encrypted: "https://hooks.example.com/old"
      )

    unreadable =
      webhook_with(
        plain: "https://hooks.example.com/x",
        ciphertext: :crypto.strong_rand_bytes(40)
      )

    report = CredentialReencryption.plain_only_report()
    webhooks = report.columns["webhooks.url"]

    refute report.clear?

    assert Map.take(webhooks, [:plain_only, :differing, :unreadable, :matching]) ==
             %{plain_only: 1, differing: 1, unreadable: 1, matching: 1}

    assert webhooks.sample_ids == %{
             plain_only: [plain_only.id],
             differing: [differing.id],
             unreadable: [unreadable.id]
           }

    refute Map.has_key?(webhooks.sample_ids, :matching)

    refute inspect(report) =~ "hooks.example.com"
  end

  test "is clear when every plain copy matches its encrypted copy" do
    webhook_with(
      plain: "https://hooks.example.com/same",
      encrypted: "https://hooks.example.com/same"
    )

    assert %{clear?: true, columns: %{"webhooks.url" => %{matching: 1}}} =
             CredentialReencryption.plain_only_report()
  end

  describe "Telegram link tokens" do
    # The current release reissues and consumes link tokens without touching
    # the plain column, so a pre-upgrade plain token outlives its link either
    # way; it must not hold the drop back.

    test "a token refreshed since the upgrade is counted, not blocking" do
      integration = insert(:telegram_integration)

      set_raw("telegram_integrations", integration.id,
        link_token: "pre-upgrade-token",
        link_token_hash: Token.hash_token("reissued-token")
      )

      assert_short_lived_only()
    end

    test "a token consumed since the upgrade (hash cleared) is counted, not blocking" do
      integration = insert(:telegram_integration)

      set_raw("telegram_integrations", integration.id,
        link_token: "pre-upgrade-token",
        link_token_hash: nil
      )

      assert_short_lived_only()
    end

    defp assert_short_lived_only do
      report = CredentialReencryption.plain_only_report()
      counts = report.columns["telegram_integrations.link_token"]

      assert report.clear?

      assert Map.take(counts, [:plain_only, :differing, :unreadable, :matching, :short_lived]) ==
               %{plain_only: 0, differing: 0, unreadable: 0, matching: 0, short_lived: 1}

      assert counts.sample_ids == %{}
    end
  end

  test "reports UUID-keyed rows by their UUID" do
    poll = insert(:poll)

    Repo.query!("UPDATE polls SET token = $1, token_encrypted = NULL WHERE id = $2", [
      poll.token,
      UUID.dump!(poll.id)
    ])

    counts = CredentialReencryption.plain_only_report().columns["polls.token"]

    assert counts.plain_only == 1
    assert counts.sample_ids == %{plain_only: [poll.id]}
  end

  test "checks every plain column the expand migrations kept, and only real columns" do
    for {table, plain, counterpart} <- PlainOnlyReport.plain_copies(),
        column <- columns(plain, counterpart) do
      %{num_rows: rows} =
        Repo.query!(
          "SELECT 1 FROM information_schema.columns WHERE table_name = $1 AND column_name = $2",
          [table, to_string(column)]
        )

      assert rows == 1, "#{table}.#{column} does not exist"
    end

    assert length(PlainOnlyReport.plain_copies()) == 9
  end

  defp columns(plain, {:encrypted, counterpart}), do: [plain, counterpart]
  defp columns(plain, :short_lived), do: [plain]

  defp webhook_with(opts) do
    webhook = insert(:webhook)

    ciphertext =
      case Keyword.fetch(opts, :ciphertext) do
        {:ok, raw} -> raw
        :error -> opts[:encrypted] && Encryption.encrypt(opts[:encrypted])
      end

    set_raw("webhooks", webhook.id, url: opts[:plain], url_encrypted: ciphertext)
    webhook
  end

  defp set_raw(table, id, changes) do
    Repo.update_all(from(r in table, where: r.id == ^id), set: changes)
  end
end
