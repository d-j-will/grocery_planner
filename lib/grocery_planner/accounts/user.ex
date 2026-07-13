defmodule GroceryPlanner.Accounts.User do
  @moduledoc false
  use Ash.Resource,
    domain: GroceryPlanner.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "users"
    repo GroceryPlanner.Repo
  end

  code_interface do
    define :create, args: [:email, :name, :password]
    define :read
    define :update
    define :confirm
    define :destroy
    define :by_id, action: :read, get_by: [:id]
    define :by_email, args: [:email], get?: true
    define :by_reset_token, args: [:token], get?: true
    define :request_password_reset
    define :reset_password, args: [:password]
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [:email, :name]
      argument :password, :string, allow_nil?: false, sensitive?: true

      change fn changeset, _ ->
        case Ash.Changeset.get_argument(changeset, :password) do
          nil ->
            changeset

          password ->
            Ash.Changeset.change_attribute(
              changeset,
              :hashed_password,
              Bcrypt.hash_pwd_salt(password)
            )
        end
      end
    end

    update :update do
      accept [:name, :email, :theme, :meal_planner_layout, :family_focus]
    end

    update :confirm do
      accept []
      require_atomic? false

      change fn changeset, _ ->
        Ash.Changeset.change_attribute(changeset, :confirmed_at, DateTime.utc_now())
      end
    end

    read :by_email do
      argument :email, :ci_string, allow_nil?: false
      filter expr(email == ^arg(:email))
    end

    read :by_reset_token do
      argument :token, :string, allow_nil?: false
      filter expr(reset_password_token == ^arg(:token))
    end

    update :request_password_reset do
      accept []
      require_atomic? false

      change fn changeset, _ ->
        token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

        changeset
        |> Ash.Changeset.change_attribute(:reset_password_token, token)
        |> Ash.Changeset.change_attribute(:reset_password_sent_at, DateTime.utc_now())
      end
    end

    update :reset_password do
      accept []
      require_atomic? false
      argument :password, :string, allow_nil?: false, sensitive?: true

      change fn changeset, _ ->
        case Ash.Changeset.get_argument(changeset, :password) do
          nil ->
            changeset

          password ->
            changeset
            |> Ash.Changeset.change_attribute(:hashed_password, Bcrypt.hash_pwd_salt(password))
            |> Ash.Changeset.change_attribute(:reset_password_token, nil)
            |> Ash.Changeset.change_attribute(:reset_password_sent_at, nil)
        end
      end
    end
  end

  policies do
    policy action_type(:create) do
      authorize_if always()
    end

    policy action_type(:read) do
      authorize_if expr(id == ^actor(:id))
      # account-mates need to see each other's name/email on the settings roster
      authorize_if relates_to_actor_via([:memberships, :account, :memberships, :user])
    end

    policy action_type([:update, :destroy]) do
      authorize_if expr(id == ^actor(:id))
    end
  end

  validations do
    validate one_of(:theme, [
               "fairway",
               "orchard",
               "marble",
               "dark"
             ])
  end

  attributes do
    uuid_primary_key :id

    attribute :email, :ci_string do
      allow_nil? false
      public? true
    end

    attribute :hashed_password, :string do
      allow_nil? false
      sensitive? true
      public? false
    end

    attribute :name, :string do
      allow_nil? false
      public? true
    end

    attribute :theme, :string do
      allow_nil? false
      default "fairway"
      public? true
    end

    attribute :meal_planner_layout, :string do
      allow_nil? false
      default "explorer"
      public? true
    end

    attribute :family_focus, :boolean do
      allow_nil? false
      default false
      public? true
    end

    attribute :confirmed_at, :utc_datetime do
      public? true
    end

    attribute :reset_password_token, :string do
      public? false
    end

    attribute :reset_password_sent_at, :utc_datetime do
      public? false
    end

    create_timestamp :created_at
    update_timestamp :updated_at
  end

  relationships do
    has_many :memberships, GroceryPlanner.Accounts.AccountMembership do
      destination_attribute :user_id
    end

    many_to_many :accounts, GroceryPlanner.Accounts.Account do
      through GroceryPlanner.Accounts.AccountMembership
      source_attribute_on_join_resource :user_id
      destination_attribute_on_join_resource :account_id
    end
  end

  identities do
    identity :unique_email, [:email]
  end
end
