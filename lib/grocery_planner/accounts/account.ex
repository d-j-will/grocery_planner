defmodule GroceryPlanner.Accounts.Account do
  @moduledoc false
  use Ash.Resource,
    domain: GroceryPlanner.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "accounts"
    repo GroceryPlanner.Repo
  end

  code_interface do
    define :create
    define :read
    define :update
    define :destroy
    define :by_id, action: :read, get_by: [:id]
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [:name, :timezone, :currency]
    end

    update :update do
      accept [:name, :timezone, :currency]
    end
  end

  policies do
    policy action(:create) do
      authorize_if always()
    end

    policy action_type(:read) do
      authorize_if relates_to_actor_via([:memberships, :user])
    end

    policy action_type([:update, :destroy]) do
      authorize_if {GroceryPlanner.Checks.ActorOwnerOrAdminOfAccount, account_id_field: :id}
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
    end

    attribute :timezone, :string do
      allow_nil? false
      default "America/New_York"
      public? true
    end

    attribute :currency, :string do
      allow_nil? false
      default "USD"
      public? true
    end

    create_timestamp :created_at
    update_timestamp :updated_at
  end

  relationships do
    has_many :memberships, GroceryPlanner.Accounts.AccountMembership do
      destination_attribute :account_id
    end

    many_to_many :users, GroceryPlanner.Accounts.User do
      through GroceryPlanner.Accounts.AccountMembership
      source_attribute_on_join_resource :account_id
      destination_attribute_on_join_resource :user_id
    end
  end
end
