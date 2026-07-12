defmodule GroceryPlanner.Checks.ActorOwnerOrAdminOfAccount do
  @moduledoc false
  use Ash.Policy.Check
  require Ash.Query

  def strict_check(actor, context, opts) when not is_nil(actor) do
    case account_id(context, opts) do
      nil ->
        {:ok, false}

      account_id ->
        exists? =
          GroceryPlanner.Accounts.AccountMembership
          |> Ash.Query.filter(
            account_id == ^account_id and user_id == ^actor.id and role in [:owner, :admin]
          )
          |> Ash.exists?(domain: GroceryPlanner.Accounts, authorize?: false)

        {:ok, exists?}
    end
  end

  def strict_check(_, _, _), do: {:ok, false}

  # On create there is no persisted record yet, so the account id comes from
  # whatever attribute/argument the changeset is setting.
  defp account_id(%{changeset: %{action_type: :create} = changeset}, opts) do
    field = Keyword.get(opts, :account_id_field, :account_id)

    Ash.Changeset.get_attribute(changeset, field) ||
      Ash.Changeset.get_argument(changeset, field)
  end

  # On update/destroy, read the account id off the existing record. Defaults to
  # `:account_id` (a belongs_to attribute) but pass `account_id_field: :id` when
  # the resource being authorized *is* the account itself.
  defp account_id(%{changeset: %{data: data}}, opts) do
    field = Keyword.get(opts, :account_id_field, :account_id)
    Map.get(data, field)
  end

  defp account_id(_, _), do: nil

  def describe(_opts), do: "actor must be an owner or admin of the account"

  def match?(_actor, _context, _opts), do: true
end
