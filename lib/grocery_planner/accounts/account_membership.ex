defmodule GroceryPlanner.Accounts.AccountMembership do
  @moduledoc false
  use Ash.Resource,
    domain: GroceryPlanner.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "account_memberships"
    repo GroceryPlanner.Repo
  end

  code_interface do
    define :create, args: [:account_id, :user_id]
    define :read
    define :update
    define :destroy
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [:role]
      argument :account_id, :uuid, allow_nil?: false
      argument :user_id, :uuid, allow_nil?: false

      change set_attribute(:account_id, arg(:account_id))
      change set_attribute(:user_id, arg(:user_id))
    end

    update :update do
      accept [:role]
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if relates_to_actor_via([:account, :memberships, :user])
    end

    policy action_type(:create) do
      authorize_if {GroceryPlanner.Checks.ActorOwnerOrAdminOfAccount, []}
    end

    policy action_type([:update, :destroy]) do
      authorize_if {GroceryPlanner.Checks.ActorOwnerOrAdminOfAccount, []}
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :role, :atom do
      allow_nil? false
      default :member
      constraints one_of: [:owner, :admin, :member]
      public? true
    end

    create_timestamp :joined_at
  end

  relationships do
    belongs_to :account, GroceryPlanner.Accounts.Account do
      allow_nil? false
      attribute_writable? true
    end

    belongs_to :user, GroceryPlanner.Accounts.User do
      allow_nil? false
      attribute_writable? true
    end
  end

  identities do
    identity :unique_user_account, [:user_id, :account_id]
  end
end
