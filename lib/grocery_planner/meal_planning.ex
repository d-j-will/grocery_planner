defmodule GroceryPlanner.MealPlanning do
  @moduledoc false
  use Ash.Domain,
    extensions: [AshJsonApi.Domain]

  json_api do
    prefix "/api/json"
  end

  resources do
    resource GroceryPlanner.MealPlanning.MealPlan do
      define :create_meal_plan, action: :create, args: [:account_id]
      define :place_meal, action: :place
      define :list_meal_plans, action: :read

      define :list_meal_plans_by_date_range,
        action: :by_date_range,
        args: [:start_date, :end_date]

      define :list_recent_meal_plans, action: :recent, args: [:since]
      define :get_meal_plan, action: :read, get_by: [:id]
      define :update_meal_plan, action: :update
      define :destroy_meal_plan, action: :destroy
      define :complete_meal_plan, action: :complete
      define :skip_meal_plan, action: :skip
      define :sync_meal_plans, action: :sync, args: [:since]
      define :pull_meal_plans, action: :sync, args: [:since, :limit]
    end

    resource GroceryPlanner.MealPlanning.MealPlanTemplate do
      define :create_meal_plan_template, action: :create, args: [:account_id]
      define :get_meal_plan_template, action: :read, get_by: [:id]
      define :update_meal_plan_template, action: :update
      define :destroy_meal_plan_template, action: :destroy
      define :activate_meal_plan_template, action: :activate
      define :deactivate_meal_plan_template, action: :deactivate
      define :list_meal_plan_templates, action: :read
      define :sync_meal_plan_templates, action: :sync, args: [:since]
      define :pull_meal_plan_templates, action: :sync, args: [:since, :limit]
    end

    resource GroceryPlanner.MealPlanning.MealPlanTemplateEntry do
      define :create_meal_plan_template_entry, action: :create, args: [:account_id]
      define :get_meal_plan_template_entry, action: :read, get_by: [:id]
      define :list_meal_plan_template_entries, action: :read
      define :list_entries_by_template, action: :list_by_template, args: [:template_id]
      define :update_meal_plan_template_entry, action: :update
      define :destroy_meal_plan_template_entry, action: :destroy
      define :sync_meal_plan_template_entries, action: :sync, args: [:since]
      define :pull_meal_plan_template_entries, action: :sync, args: [:since, :limit]
    end

    resource GroceryPlanner.MealPlanning.MealPlanVoteSession do
      define :create_vote_session, action: :start, args: [:account_id]
      define :create_vote_session_from_api, action: :create_from_api, args: [:account_id]
      define :list_vote_sessions, action: :read
      define :get_vote_session, action: :read, get_by: [:id]
      define :update_vote_session, action: :update
      define :close_vote_session, action: :close
      define :mark_session_processed, action: :mark_processed
      define :destroy_vote_session, action: :destroy
      define :sync_vote_sessions, action: :sync, args: [:since]
      define :pull_vote_sessions, action: :sync, args: [:since, :limit]
    end

    resource GroceryPlanner.MealPlanning.MealPlanVoteEntry do
      define :create_vote_entry,
        action: :vote,
        args: [:account_id, :vote_session_id, :recipe_id, :user_id]

      define :create_vote_entry_from_api, action: :create_from_api, args: [:vote_session_id]
      define :list_vote_entries, action: :read
      define :get_vote_entry, action: :read, get_by: [:id]
      define :list_vote_entries_by_session, action: :list_by_session, args: [:vote_session_id]
      define :list_entries_for_session, action: :by_session, args: [:vote_session_id]
      define :destroy_vote_entry, action: :destroy
      define :sync_vote_entries, action: :sync, args: [:since]
      define :pull_vote_entries, action: :sync, args: [:since, :limit]
    end
  end

  @doc """
  Swaps the (scheduled_date, meal_type) slots of two meals.

  The partial unique slot index is *immediate*, so Postgres checks it per row
  within a statement — a single swapping UPDATE (or two sequential updates)
  still trips it because one row transiently lands on the other's slot. Instead,
  within a transaction, we hide meal_a via `deleted_at` (which drops it out of
  the `WHERE deleted_at IS NULL` index, freeing its slot), move meal_b into that
  slot, then move meal_a into meal_b's now-free slot and un-hide it. Row ids are
  preserved. Both meals belong to the same account (loaded/authorized by the
  caller). See grocery_planner-vzc.
  """
  def swap_meal_slots(%{account_id: account_id} = meal_a, %{account_id: account_id} = meal_b) do
    repo = GroceryPlanner.Repo
    a_id = Ecto.UUID.dump!(meal_a.id)
    b_id = Ecto.UUID.dump!(meal_b.id)
    acct = Ecto.UUID.dump!(account_id)

    result =
      repo.transaction(fn ->
        # Every UPDATE is scoped by account_id as well as id: the raw SQL bypasses
        # Ash's automatic tenant enforcement, so a row from another tenant must
        # never be touched even if a stale/forged id reaches here.
        with {:ok, _} <-
               Ecto.Adapters.SQL.query(
                 repo,
                 "UPDATE meal_plans SET deleted_at = (now() AT TIME ZONE 'utc') WHERE id = $1 AND account_id = $2",
                 [a_id, acct]
               ),
             {:ok, _} <-
               Ecto.Adapters.SQL.query(
                 repo,
                 "UPDATE meal_plans SET scheduled_date = $2::date, meal_type = $3, updated_at = (now() AT TIME ZONE 'utc') WHERE id = $1 AND account_id = $4",
                 [b_id, meal_a.scheduled_date, to_string(meal_a.meal_type), acct]
               ),
             {:ok, _} <-
               Ecto.Adapters.SQL.query(
                 repo,
                 "UPDATE meal_plans SET scheduled_date = $2::date, meal_type = $3, deleted_at = NULL, updated_at = (now() AT TIME ZONE 'utc') WHERE id = $1 AND account_id = $4",
                 [a_id, meal_b.scheduled_date, to_string(meal_b.meal_type), acct]
               ) do
          :ok
        else
          {:error, reason} -> repo.rollback(reason)
        end
      end)

    case result do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Both meals must belong to the same account — a cross-account swap is a bug,
  # never a valid operation. Reject it rather than silently touching two tenants.
  def swap_meal_slots(_meal_a, _meal_b), do: {:error, :cross_account_swap}
end
