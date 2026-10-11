defmodule TymeslotWeb.Helpers.FormErrorsTest do
  use ExUnit.Case, async: true
  @moduletag :utils

  import Ecto.Changeset

  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias TymeslotWeb.Helpers.FormErrors

  @types %{name: :string, title: :string, count: :integer}

  defmodule Item do
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field :title, :string
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(item, attrs), do: item |> cast(attrs, [:title]) |> validate_required([:title])
  end

  defmodule Parent do
    use Ecto.Schema

    embedded_schema do
      field :label, :string
      embeds_many :items, Item
    end
  end

  defp changeset(attrs) do
    {%{}, @types}
    |> cast(attrs, Map.keys(@types))
    |> validate_required([:title])
    |> validate_length(:name, min: 3)
    |> validate_number(:count, greater_than: 0)
  end

  defp in_locale(locale, fun), do: Gettext.with_locale(TymeslotWeb.Gettext, locale, fun)

  describe "to_map/1" do
    test "interpolates every placeholder" do
      assert FormErrors.to_map(changeset(%{name: "ab", count: 0})) == %{
               title: ["can't be blank"],
               name: ["should be at least 3 character(s)"],
               count: ["must be greater than 0"]
             }
    end

    test "translates into the current locale" do
      errors = in_locale("de", fn -> FormErrors.to_map(changeset(%{name: "ab"})) end)

      assert errors.title == ["darf nicht leer sein"]
      assert errors.name == ["sollte mindestens 3 Zeichen lang sein"]
    end

    # The group rules are refused in the domain with an `errors` msgid; the
    # meeting type form shows them in the host's language like any other error.
    test "translates a domain refusal into the current locale" do
      changeset =
        MeetingTypeSchema.changeset(%MeetingTypeSchema{}, %{
          name: "Workshop",
          duration_minutes: 60,
          user_id: 1,
          max_participants: 5,
          requires_approval: true
        })

      errors = in_locale("de", fn -> FormErrors.to_map(changeset) end)

      assert "Gruppenbuchungen können keine Bestätigung erfordern" in errors.max_participants
    end

    test "is empty for a valid changeset" do
      assert FormErrors.to_map(changeset(%{title: "Valid"})) == %{}
    end
  end

  describe "first_per_field/1" do
    test "keeps each field's first message" do
      cs = add_error(changeset(%{name: "ab"}), :name, "is reserved")

      assert FormErrors.first_per_field(cs) == %{
               title: "can't be blank",
               name: "is reserved"
             }
    end
  end

  describe "first/1" do
    test "names the first field alphabetically, humanised" do
      assert FormErrors.first(changeset(%{name: "ab", count: 0})) ==
               "Count must be greater than 0"
    end

    test "translates the message" do
      assert in_locale("de", fn -> FormErrors.first(changeset(%{})) end) ==
               "Title darf nicht leer sein"
    end

    test "reaches a message nested under an embedded field" do
      cs =
        %Parent{}
        |> cast(%{label: "ok", items: [%{title: "fine"}, %{title: ""}]}, [:label])
        |> cast_embed(:items, with: &Item.changeset/2)

      assert FormErrors.first(cs) == "Items can't be blank"
    end

    test "is nil for a valid changeset" do
      assert FormErrors.first(changeset(%{title: "Valid"})) == nil
    end
  end
end
