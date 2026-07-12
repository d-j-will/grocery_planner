defmodule GroceryPlanner.Checks.ActorMemberOfAccount do
  @moduledoc false
  use Ash.Policy.Check
  require Ash.Query

  def strict_check(actor, %{changeset: %{action_type: :create} = changeset}, _opts)
      when not is_nil(actor) do
    account_id =
      Ash.Changeset.get_attribute(changeset, :account_id) ||
        Ash.Changeset.get_argument(changeset, :account_id)

    exists? =
      GroceryPlanner.Accounts.AccountMembership
      |> Ash.Query.filter(account_id == ^account_id and user_id == ^actor.id)
      |> Ash.exists?(domain: GroceryPlanner.Accounts, authorize?: false)

    {:ok, exists?}
  end

  def strict_check(_, _, _), do: {:ok, false}

  def describe(_opts) do
    "actor must be a member of the account"
  end

  def match?(_actor, _context, _opts), do: true
end
