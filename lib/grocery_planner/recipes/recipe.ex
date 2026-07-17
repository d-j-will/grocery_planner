defmodule GroceryPlanner.Recipes.Recipe do
  @moduledoc false
  use Ash.Resource,
    domain: GroceryPlanner.Recipes,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshJsonApi.Resource, AshAi, AshOban],
    primary_read_warning?: false

  postgres do
    table "recipes"
    repo GroceryPlanner.Repo
  end

  json_api do
    type "recipe"

    routes do
      base("/recipes")
      get(:read)
      index :read
      post(:create)
      patch(:update)
      delete(:destroy)
    end
  end

  vectorize do
    # Target the existing `:embedding` column (add_embeddings migration + the
    # attribute below), NOT ash_ai's default `:full_text_vector` — there is no
    # such column, so the declarative update failed with 42703 and semantic
    # search silently ran on never-written vectors (z7h). This is also the column
    # the recipe search reads.
    full_text do
      name :embedding

      text(fn recipe ->
        ingredients =
          case recipe do
            %{recipe_ingredients: ingredients} when is_list(ingredients) ->
              ingredients
              |> Enum.map(fn ri ->
                case ri do
                  %{grocery_item: %{name: name}} -> name
                  %{name: name} when is_binary(name) -> name
                  _ -> nil
                end
              end)
              |> Enum.reject(&is_nil/1)
              |> Enum.join(", ")

            _ ->
              ""
          end

        dietary =
          case recipe.dietary_needs do
            needs when is_list(needs) -> Enum.map_join(needs, ", ", &to_string/1)
            _ -> ""
          end

        [
          recipe.name,
          recipe.description,
          if(ingredients != "", do: "Ingredients: #{ingredients}"),
          if(recipe.cuisine, do: "Cuisine: #{recipe.cuisine}"),
          if(dietary != "", do: "Dietary: #{dietary}"),
          if(recipe.difficulty, do: "Difficulty: #{recipe.difficulty}"),
          if(recipe.prep_time_minutes || recipe.cook_time_minutes,
            do:
              "Time: #{(recipe.prep_time_minutes || 0) + (recipe.cook_time_minutes || 0)} minutes"
          )
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join(". ")
      end)

      used_attributes([
        :name,
        :description,
        :cuisine,
        :difficulty,
        :dietary_needs,
        :prep_time_minutes,
        :cook_time_minutes
      ])
    end

    strategy :ash_oban
    embedding_model(GroceryPlanner.AI.EmbeddingModel)
  end

  oban do
    triggers do
      trigger :ash_ai_update_embeddings do
        action :ash_ai_update_embeddings
        worker_read_action(:read)
        queue(:ai_jobs)
        max_attempts(3)
        worker_module_name(GroceryPlanner.Recipes.Recipe.AshOban.Worker.AshAiUpdateEmbeddings)

        scheduler_module_name(
          GroceryPlanner.Recipes.Recipe.AshOban.Scheduler.AshAiUpdateEmbeddings
        )
      end
    end
  end

  code_interface do
    domain GroceryPlanner.Recipes

    define :list_favorite_recipes, action: :favorites
    define :list_recipes_for_meal_planner, action: :meal_planner_recipes
    define :list_recipes_sorted, action: :list_all_sorted
    define :read
    define :create
    define :update
    define :destroy
  end

  actions do
    defaults []

    read :read do
      primary? true
      filter expr(is_nil(deleted_at))
      pagination keyset?: true, required?: false
    end

    destroy :destroy do
      primary? true
      soft? true
      change set_attribute(:deleted_at, &DateTime.utc_now/0)
    end

    # Cross-tenant stream for the embedding backfill (z7h). `allow_global` so a
    # single pass spans every account; the backfill sets each record's tenant
    # from `account_id` when it enqueues the trigger. Called only with
    # `authorize?: false` from GroceryPlanner.Recipes.EmbeddingBackfill.
    read :stream_for_backfill do
      multitenancy :allow_global
      filter expr(is_nil(deleted_at))
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

    read :meal_planner_recipes do
      filter expr(is_nil(deleted_at))

      prepare build(
                load: [
                  :total_time_minutes,
                  :can_make,
                  :ingredient_availability,
                  recipe_ingredients: [:grocery_item],
                  follow_up_recipes: [recipe_ingredients: [:grocery_item]],
                  parent_recipe: [follow_up_recipes: [recipe_ingredients: [:grocery_item]]]
                ]
              )

      prepare build(sort: [name: :asc])
    end

    create :create do
      accept [
        :name,
        :description,
        :instructions,
        :prep_time_minutes,
        :cook_time_minutes,
        :servings,
        :difficulty,
        :image_url,
        :source,
        :is_favorite,
        :is_base_recipe,
        :is_follow_up,
        :parent_recipe_id,
        :freezable,
        :preservation_tip,
        :waste_reduction_tip,
        :cuisine,
        :dietary_needs
      ]

      argument :account_id, :uuid, allow_nil?: false

      change manage_relationship(:account_id, :account, type: :append)
    end

    update :update do
      accept [
        :name,
        :description,
        :instructions,
        :prep_time_minutes,
        :cook_time_minutes,
        :servings,
        :difficulty,
        :image_url,
        :source,
        :is_favorite,
        :is_base_recipe,
        :is_follow_up,
        :parent_recipe_id,
        :freezable,
        :preservation_tip,
        :waste_reduction_tip,
        :cuisine,
        :dietary_needs
      ]

      require_atomic? false
    end

    update :toggle_base_recipe do
      accept []

      change fn changeset, _ ->
        current = Ash.Changeset.get_attribute(changeset, :is_base_recipe)
        Ash.Changeset.change_attribute(changeset, :is_base_recipe, !current)
      end

      require_atomic? false
    end

    update :toggle_favorite do
      accept []

      change fn changeset, _ ->
        current = Ash.Changeset.get_attribute(changeset, :is_favorite)
        Ash.Changeset.change_attribute(changeset, :is_favorite, !current)
      end

      require_atomic? false
    end

    update :link_as_follow_up do
      argument :parent_recipe_id, :uuid, allow_nil?: false

      change fn changeset, _ ->
        parent_id = Ash.Changeset.get_argument(changeset, :parent_recipe_id)

        changeset
        |> Ash.Changeset.change_attribute(:is_follow_up, true)
        |> Ash.Changeset.change_attribute(:parent_recipe_id, parent_id)
      end

      require_atomic? false
    end

    update :unlink_from_parent do
      accept []

      change fn changeset, _ ->
        changeset
        |> Ash.Changeset.change_attribute(:is_follow_up, false)
        |> Ash.Changeset.change_attribute(:parent_recipe_id, nil)
      end

      require_atomic? false
    end

    read :favorites do
      filter expr(is_nil(deleted_at))
      filter expr(is_favorite == true)
      prepare build(sort: [name: :asc])
    end

    read :list_all_sorted do
      filter expr(is_nil(deleted_at))
      prepare build(sort: [name: :asc])
    end

    # Deep recipe-browsing seam: one filtered/sorted/paginated read that replaces
    # the in-memory filter/sort duplicated across the recipe LiveViews. All args
    # are optional (nil/blank = no-op). Named to mirror FilterPreset.criteria keys.
    read :browse do
      argument :search, :string
      argument :difficulty, :atom
      argument :prep_time, :atom
      argument :favorites, :boolean
      argument :chains, :boolean
      argument :cuisine, :string
      argument :dietary_needs, {:array, :atom}
      argument :sort_by, :string

      pagination offset?: true, required?: false, countable: true

      filter expr(is_nil(deleted_at))

      prepare GroceryPlanner.Recipes.Preparations.BrowseRecipes
    end
  end

  policies do
    # The ash_ai embedding trigger runs the worker READ (via `:read`) and the
    # embedding UPDATE with NO actor. Without this bypass the `:read` action's
    # `relates_to_actor_via` policy returns empty for a nil actor, so AshOban sees
    # the record as gone and cancels the job (`:trigger_no_longer_applies`) — the
    # embedding silently never persists (z7h). AshObanInteraction only matches
    # inside an AshOban trigger's own execution, and tenant isolation is still
    # enforced by attribute multitenancy, so this opens nothing to normal callers.
    bypass AshOban.Checks.AshObanInteraction do
      authorize_if always()
    end

    bypass action(:ash_ai_update_embeddings) do
      authorize_if always()
    end

    policy action_type(:read) do
      authorize_if relates_to_actor_via([:account, :memberships, :user])
    end

    policy action_type(:create) do
      authorize_if GroceryPlanner.Checks.ActorMemberOfAccount
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

    attribute :name, :string do
      allow_nil? false
      public? true
    end

    attribute :description, :string do
      public? true
    end

    attribute :instructions, :string do
      public? true
    end

    attribute :prep_time_minutes, :integer do
      public? true
    end

    attribute :cook_time_minutes, :integer do
      public? true
    end

    attribute :servings, :integer do
      default 4
      public? true
    end

    attribute :difficulty, :atom do
      constraints one_of: [:easy, :medium, :hard]
      default :medium
      public? true
    end

    attribute :image_url, :string do
      public? true
    end

    attribute :source, :string do
      public? true
    end

    attribute :is_favorite, :boolean do
      default false
      public? true
    end

    attribute :is_base_recipe, :boolean do
      default false
      public? true
      description "If true, this recipe is designed to produce leftovers for other meals."
    end

    attribute :is_follow_up, :boolean do
      default false
      public? true
      description "If true, this recipe is designed to use leftovers from a base meal."
    end

    attribute :freezable, :boolean do
      default false
      public? true
    end

    attribute :preservation_tip, :string do
      public? true
    end

    attribute :waste_reduction_tip, :string do
      public? true
    end

    attribute :cuisine, :string do
      public? true
    end

    attribute :dietary_needs, {:array, :atom} do
      public? true
      default []

      constraints items: [
                    one_of: [
                      :vegan,
                      :vegetarian,
                      :pescatarian,
                      :gluten_free,
                      :dairy_free,
                      :nut_free,
                      :halal,
                      :kosher,
                      :keto,
                      :paleo
                    ]
                  ]
    end

    attribute :account_id, :uuid do
      allow_nil? false
      public? true
    end

    # `:embedding` is declared by the ash_ai `vectorize` block (full_text name
    # :embedding) — ash_ai insists on creating the vector field itself and errors
    # if it's already declared here. The add_embeddings migration created the
    # matching `embedding vector(384)` column, so no schema change.
    attribute :embedding_model, :string

    attribute :embedding_updated_at, :utc_datetime

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

    has_many :recipe_ingredients, GroceryPlanner.Recipes.RecipeIngredient do
      destination_attribute :recipe_id
    end

    many_to_many :tags, GroceryPlanner.Recipes.RecipeTag do
      through GroceryPlanner.Recipes.RecipeTagging
      source_attribute_on_join_resource :recipe_id
      destination_attribute_on_join_resource :tag_id
    end

    has_many :meal_plans, GroceryPlanner.MealPlanning.MealPlan do
      destination_attribute :recipe_id
    end

    belongs_to :parent_recipe, GroceryPlanner.Recipes.Recipe do
      public? true
      description "The base recipe this recipe is derived from."
    end

    has_many :follow_up_recipes, GroceryPlanner.Recipes.Recipe do
      destination_attribute :parent_recipe_id
    end

    has_many :recipe_preferences, GroceryPlanner.Family.RecipePreference do
      destination_attribute :recipe_id
    end
  end

  calculations do
    calculate :total_time_minutes, :integer do
      calculation expr(prep_time_minutes + cook_time_minutes)
    end

    calculate :ingredient_availability,
              :decimal,
              GroceryPlanner.Recipes.Calculations.IngredientAvailability do
      description "Percentage of recipe ingredients currently in stock (0.0 to 100.0)"
    end

    calculate :can_make, :boolean, GroceryPlanner.Recipes.Calculations.CanMake do
      description "Whether all required ingredients are currently available in inventory"
    end

    calculate :missing_ingredients,
              {:array, :string},
              GroceryPlanner.Recipes.Calculations.MissingIngredients do
      description "List of ingredient names not currently available in inventory"
    end
  end
end
