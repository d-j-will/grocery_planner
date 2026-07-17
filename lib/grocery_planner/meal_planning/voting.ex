defmodule GroceryPlanner.MealPlanning.Voting do
  @moduledoc false
  require Ash.Query
  alias GroceryPlanner.MealPlanning
  alias GroceryPlanner.MealPlanning.MealPlanVoteEntry

  def start_vote(account_id, actor) do
    MealPlanning.create_vote_session(account_id, %{}, actor: actor, tenant: account_id)
  end

  def open_session(account_id, actor) do
    case MealPlanning.list_vote_sessions(actor: actor, tenant: account_id) do
      {:ok, sessions} ->
        session =
          Enum.find(sessions, fn s ->
            s.account_id == account_id && s.status == :open
          end)

        {:ok, session}

      {:error, _} = error ->
        error
    end
  end

  def voting_active?(account_id, actor) do
    case open_session(account_id, actor) do
      {:ok, session} when not is_nil(session) -> true
      _ -> false
    end
  end

  def cast_vote(session_id, recipe_id, account_id, actor) do
    MealPlanning.create_vote_entry(
      account_id,
      session_id,
      recipe_id,
      actor.id,
      %{},
      actor: actor,
      tenant: account_id
    )
  end

  def remove_vote(session_id, recipe_id, account_id, actor) do
    case MealPlanning.list_vote_entries(
           actor: actor,
           tenant: account_id,
           query:
             MealPlanVoteEntry
             |> Ash.Query.filter(
               vote_session_id == ^session_id and recipe_id == ^recipe_id and user_id == ^actor.id
             )
         ) do
      {:ok, [entry]} ->
        case MealPlanning.destroy_vote_entry(entry, actor: actor, tenant: account_id) do
          :ok -> {:ok, nil}
          {:error, _} = error -> error
        end

      {:ok, []} ->
        {:ok, nil}

      {:ok, _} ->
        {:error, :multiple_entries}

      {:error, _} = error ->
        error
    end
  end

  def finalize_session(session_id, account_id, actor) do
    with {:ok, session} <-
           MealPlanning.get_vote_session(session_id, tenant: account_id, actor: actor),
         true <- session.status in [:open, :closed],
         true <- DateTime.compare(DateTime.utc_now(), session.ends_at) != :lt,
         {:ok, entries} <- list_entries(session_id, account_id, actor) do
      winning_recipe_ids = pick_winners(entries)
      {:ok, _} = mark_processed(session, winning_recipe_ids, account_id, actor)
      {:ok, created_meals} = distribute_winners(winning_recipe_ids, account_id, actor)
      {:ok, %{winning_recipe_ids: winning_recipe_ids, created_meal_plans: created_meals}}
    else
      false -> {:error, :not_ready}
      {:error, error} -> {:error, error}
      _ -> {:error, :finalize_failed}
    end
  end

  defp list_entries(session_id, account_id, actor) do
    MealPlanning.list_vote_entries(
      actor: actor,
      tenant: account_id,
      query:
        MealPlanVoteEntry
        |> Ash.Query.filter(account_id == ^account_id and vote_session_id == ^session_id)
    )
  end

  defp pick_winners(entries) do
    entries
    |> Enum.group_by(& &1.recipe_id)
    |> Enum.map(fn {recipe_id, votes} -> {recipe_id, length(votes)} end)
    |> Enum.group_by(fn {_recipe_id, count} -> count end)
    |> Enum.sort_by(fn {count, _list} -> count end, :desc)
    |> Enum.flat_map(fn {_count, list} -> Enum.shuffle(list) end)
    |> Enum.map(fn {recipe_id, _count} -> recipe_id end)
  end

  defp mark_processed(session, winning_recipe_ids, account_id, actor) do
    MealPlanning.mark_session_processed(
      session,
      %{winning_recipe_ids: winning_recipe_ids},
      actor: actor,
      tenant: account_id
    )
  end

  defp distribute_winners(winning_recipe_ids, account_id, actor) do
    week_start = next_week_start(Date.utc_today())
    dates = Enum.map(0..6, fn i -> Date.add(week_start, i) end)
    dinner_slot_count = length(dates)
    chosen = Enum.take(winning_recipe_ids, dinner_slot_count)

    created =
      Enum.reduce(Enum.zip(dates, chosen), [], fn {date, recipe_id}, acc ->
        case create_meal_plan(date, recipe_id, account_id, actor) do
          {:ok, meal} -> [meal | acc]
          {:error, _} -> acc
        end
      end)

    {:ok, Enum.reverse(created)}
  end

  defp create_meal_plan(date, recipe_id, account_id, actor) do
    MealPlanning.create_meal_plan(
      account_id,
      %{
        recipe_id: recipe_id,
        scheduled_date: date,
        meal_type: :dinner,
        servings: 4
      },
      actor: actor,
      tenant: account_id
    )
  end

  defp next_week_start(today) do
    this_week_start = get_week_start(today)
    Date.add(this_week_start, 7)
  end

  defp get_week_start(date) do
    dow = Date.day_of_week(date)
    Date.add(date, -(dow - 1))
  end
end
