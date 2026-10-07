defmodule Tymeslot.Security.FieldValidators.FullNameValidatorTest do
  use Tymeslot.DataCase, async: true

  @moduletag :security

  alias Tymeslot.Security.FieldValidators.FullNameValidator

  describe "validate/2" do
    test "returns :ok for valid full names" do
      assert :ok = FullNameValidator.validate("John Smith")
      assert :ok = FullNameValidator.validate("José María")
      assert :ok = FullNameValidator.validate("O'Connor")
      assert :ok = FullNameValidator.validate("Anne-Marie")
    end

    test "returns :ok for nil or empty string (optional field)" do
      assert :ok = FullNameValidator.validate(nil)
      assert :ok = FullNameValidator.validate("")
      assert :ok = FullNameValidator.validate("   ")
    end

    test "returns error for long names" do
      long_name = String.duplicate("a", 101)

      assert {:error, "Name is too long (maximum 100 characters)"} =
               FullNameValidator.validate(long_name)
    end

    test "returns error for invalid characters" do
      assert {:error, "Name contains invalid characters"} =
               FullNameValidator.validate("John<script>")

      assert {:error, "Name contains invalid characters"} =
               FullNameValidator.validate("Name;")
    end

    test "returns error for only numbers" do
      assert {:error, "Name cannot be only numbers"} = FullNameValidator.validate("12345")

      assert {:error, "Name cannot be only numbers"} =
               FullNameValidator.validate("123 45")
    end

    test "returns error for excessive whitespace" do
      assert {:error, "Name contains excessive whitespace"} =
               FullNameValidator.validate("John   Smith")
    end

    test "supports custom max_length option" do
      assert {:error, "Name is too long (maximum 5 characters)"} =
               FullNameValidator.validate("Too long", max_length: 5)
    end

    test "returns error for non-binary values" do
      assert {:error, "Name must be a text value"} = FullNameValidator.validate(123)

      assert {:error, "Name must be a text value"} =
               FullNameValidator.validate(%{key: "value"})
    end
  end

  # The same validator serves the profile's "Display Name" and the
  # onboarding's "Your name", so its messages say "Name", which reads right
  # under either label, in every locale.
  describe "validate/2 in another language" do
    test "names the field neutrally" do
      Gettext.with_locale(TymeslotWeb.Gettext, "de", fn ->
        assert {:error, "Name darf nicht nur aus Zahlen bestehen"} =
                 FullNameValidator.validate("12345")
      end)
    end
  end
end
