defmodule GroceryPlanner.MealPlanning.MealPlan do
  @moduledoc false
  use Ash.Resource,
    domain: GroceryPlanner.MealPlanning,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshJsonApi.Resource],
    primary_read_warning?: false

  postgres do
    table "meal_plans"
    repo GroceryPlanner.Repo

    # Maps the :unique_slot_per_account identity's `where is_nil(deleted_at)` to
    # raw SQL. AshPostgres uses this for both the partial unique index and the
    # `:place` upsert's ON CONFLICT (...) WHERE deleted_at IS NULL target.
    identity_wheres_to_sql unique_slot_per_account: "deleted_at IS NULL"
  end

  json_api do
    type "meal_plan"

    routes do
      base("/meal_plans")
      get(:read)
      index :read
      post(:create)
      patch(:update)
      delete(:destroy)

      patch(:complete, route: "/:id/complete")
    end
  end

  code_interface do
    domain GroceryPlanner.MealPlanning

    define :create_meal_plan, action: :create
    define :update_meal_plan, action: :update
    define :list_meal_plans_by_date_range, action: :by_date_range, args: [:start_date, :end_date]
    define :list_recent_meal_plans, action: :recent, args: [:since]
    define :read
    define :destroy
  end

  actions do
    defaults []

    read :read do
      primary? true
      filter expr(is_nil(deleted_at))
    end

    destroy :destroy do
      primary? true
      soft? true
      change set_attribute(:deleted_at, &DateTime.utc_now/0)
    end

    read :sync do
      argument :since, :utc_datetime_usec
      argument :limit, :integer

      filter expr(
               if is_nil(^arg(:since)) do
                 true
               else
                 updated_at >= ^arg(:since) or
                   (not is_nil(deleted_at) and deleted_at >= ^arg(:since))
               end
             )

      prepare build(sort: [updated_at: :asc])

      prepare fn query, _context ->
        case Ash.Query.get_argument(query, :limit) do
          nil -> query
          limit -> Ash.Query.limit(query, limit)
        end
      end
    end

    create :create do
      accept [
        :recipe_id,
        :scheduled_date,
        :meal_type,
        :servings,
        :notes,
        :status
      ]

      argument :account_id, :uuid, allow_nil?: false

      change manage_relationship(:account_id, :account, type: :append)
    end

    # Create-or-replace the meal occupying a slot. Interactive paths (drag-drop,
    # quick-add, follow-up suggestions) and undo-restore use this so a slot never
    # doubles: on conflict with a live row for (account_id, scheduled_date,
    # meal_type) it replaces the occupant's content in place. account_id is set
    # from the tenant, so no relationship management is needed (which also keeps
    # it compatible with the upsert path). See grocery_planner-vzc.
    create :place do
      upsert? true
      upsert_identity :unique_slot_per_account
      upsert_fields [:recipe_id, :servings, :notes, :status, :completed_at]

      accept [
        :recipe_id,
        :scheduled_date,
        :meal_type,
        :servings,
        :notes
      ]

      change set_attribute(:status, :planned)
      change set_attribute(:completed_at, nil)
    end

    update :update do
      accept [
        :recipe_id,
        :scheduled_date,
        :meal_type,
        :servings,
        :notes,
        :status,
        :completed_at
      ]

      require_atomic? false
    end

    update :complete do
      accept []

      change set_attribute(:status, :completed)
      change set_attribute(:completed_at, &DateTime.utc_now/0)

      require_atomic? false
    end

    update :skip do
      accept []

      change set_attribute(:status, :skipped)

      require_atomic? false
    end

    read :by_date_range do
      argument :start_date, :date, allow_nil?: false
      argument :end_date, :date, allow_nil?: false

      filter expr(is_nil(deleted_at))
      filter expr(scheduled_date >= ^arg(:start_date) and scheduled_date < ^arg(:end_date))
    end

    read :recent do
      argument :since, :date, allow_nil?: false

      filter expr(is_nil(deleted_at))
      filter expr(scheduled_date >= ^arg(:since))
      prepare build(sort: [scheduled_date: :desc])
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if relates_to_actor_via([:account, :memberships, :user])
    end

    policy action_type(:create) do
      authorize_if always()
    end

    policy action_type([:update, :destroy]) do
      authorize_if relates_to_actor_via([:account, :memberships, :user])
    end
  end

  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  attributes do
    uuid_primary_key :id

    attribute :scheduled_date, :date do
      allow_nil? false
      public? true
    end

    attribute :meal_type, :atom do
      constraints one_of: [:breakfast, :lunch, :dinner, :snack]
      allow_nil? false
      public? true
    end

    attribute :servings, :integer do
      default 4
      public? true
    end

    attribute :notes, :string do
      public? true
    end

    attribute :status, :atom do
      constraints one_of: [:planned, :completed, :skipped]
      default :planned
      public? true
    end

    attribute :completed_at, :utc_datetime do
      public? true
    end

    attribute :recipe_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :account_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :deleted_at, :utc_datetime_usec do
      public? true
    end

    create_timestamp :created_at, public?: true
    update_timestamp :updated_at, public?: true
  end

  relationships do
    belongs_to :account, GroceryPlanner.Accounts.Account do
      allow_nil? false
      attribute_writable? true
    end

    belongs_to :recipe, GroceryPlanner.Recipes.Recipe do
      allow_nil? false
      attribute_writable? true
    end
  end

  calculations do
    calculate :requires_shopping, :boolean do
      calculation expr(not recipe.can_make)
    end
  end

  identities do
    # One live meal per (account_id, scheduled_date, meal_type). Partial on
    # deleted_at so soft-deleting a meal frees its slot for a new one — a full
    # index would keep the tombstone occupying the slot. account_id is the
    # tenant attribute; listing it explicitly follows the repo convention
    # (e.g. RecipeTag.unique_name_per_account). See grocery_planner-vzc.
    identity :unique_slot_per_account, [:account_id, :scheduled_date, :meal_type] do
      where expr(is_nil(deleted_at))
    end
  end
end
