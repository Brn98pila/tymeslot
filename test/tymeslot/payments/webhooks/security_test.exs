defmodule Tymeslot.Payments.Webhooks.SecurityTest do
  use Tymeslot.DataCase, async: false
  @moduletag :payments

  alias Tymeslot.Payments.Webhooks.Security.DevelopmentMode
  import Tymeslot.ConfigTestHelpers

  describe "DevelopmentMode" do
    test "verify_if_allowed/1 returns error when not allowed" do
      with_config(:tymeslot, skip_webhook_verification: false)
      assert {:error, :not_allowed} = DevelopmentMode.verify_if_allowed("{}")
    end

    test "verify_if_allowed/1 parses JSON when allowed" do
      with_config(:tymeslot,
        skip_webhook_verification: true,
        environment: :test
      )

      assert {:ok, %{"id" => "evt_123"}} =
               DevelopmentMode.verify_if_allowed(~S({"id": "evt_123"}))
    end

    test "verify_if_allowed/1 returns error on invalid JSON" do
      with_config(:tymeslot,
        skip_webhook_verification: true,
        environment: :test
      )

      assert {:error, %{reason: :invalid_json}} = DevelopmentMode.verify_if_allowed("invalid")
    end
  end
end
