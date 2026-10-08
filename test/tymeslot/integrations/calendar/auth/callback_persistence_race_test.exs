defmodule Tymeslot.Integrations.Calendar.CallbackPersistenceRaceTest do
  @moduledoc """
  A callback that loses the insert race to a concurrent callback for the same
  provider account: both looked the account up and found nothing, the other
  inserted first, and this insert hits the account's unique index. It must
  reconnect the row that won, as any reconnect does.
  """

  # async: false: meck replaces CalendarIntegrationQueries for every process.
  use Tymeslot.DataCase, async: false

  @moduletag :integrations

  use Oban.Testing, repo: Tymeslot.Repo

  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.CallbackPersistence
  alias Tymeslot.Workers.IntegrationHealthWorker

  setup do
    :meck.new(CalendarIntegrationQueries, [:passthrough])

    # meck unloads the module itself when the test process exits.
    on_exit(fn ->
      try do
        :meck.unload(CalendarIntegrationQueries)
      rescue
        _not_mocked -> :ok
      end
    end)
  end

  test "reconnects the row a concurrent callback inserted first" do
    user = insert(:user)
    insert(:profile, user: user)

    winner =
      insert(:calendar_integration,
        user: user,
        provider: "google",
        provider_account_id: "sub-race",
        calendar_list: [%{"id" => "cal1", "name" => "Primary", "selected" => true}]
      )

    # Both lookups made before the insert ran before the winner existed; the
    # one after the refused insert sees it.
    :meck.expect(CalendarIntegrationQueries, :get_any_by_account_for_user, fn _user, _p, _a ->
      {:error, :not_found}
    end)

    :meck.expect(CalendarIntegrationQueries, :get_by_account_for_user, fn user_id,
                                                                          provider,
                                                                          account ->
      if Process.put(:looked_up_before_insert, true) do
        :meck.passthrough([user_id, provider, account])
      else
        {:error, :not_found}
      end
    end)

    tokens = %{
      access_token: "race-access",
      refresh_token: "race-refresh",
      expires_at: DateTime.add(DateTime.utc_now(:second), 3600, :second),
      scope: "calendar",
      provider_account_id: "sub-race",
      provider_account_email: "race@example.com"
    }

    assert {:ok, %{id: id}} = CallbackPersistence.upsert("google", user.id, nil, tokens)
    assert id == winner.id

    # The refused insert is what sent it back to look the account up again.
    assert :meck.num_calls(CalendarIntegrationQueries, :get_by_account_for_user, :_) == 2

    stored = Repo.get!(CalendarIntegrationSchema, winner.id)
    assert CalendarIntegrationSchema.decrypt_oauth_tokens(stored).access_token == "race-access"
    assert [_one] = Repo.all(CalendarIntegrationSchema)

    assert_enqueued(
      worker: IntegrationHealthWorker,
      args: %{"type" => "calendar", "integration_id" => winner.id}
    )
  end
end
