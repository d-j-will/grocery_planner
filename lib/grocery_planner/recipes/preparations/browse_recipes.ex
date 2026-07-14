defmodule GroceryPlanner.Recipes.Preparations.BrowseRecipes do
  @moduledoc """
  Applies the optional filters and sort for the Recipe `:browse` action.

  All recipe-browsing rules live here so they have one home (locality) and run in
  Postgres, replacing the in-memory `filter_by_*`/`sort_recipes` logic that was
  duplicated across the recipe LiveViews. Every argument is optional — a nil or
  blank value is a no-op — so one action serves every caller.

  Sorts always append `id: :asc` as a final tiebreaker: the primary keys
  (`name`, `difficulty`, total time) are non-unique, and offset pagination over a
  non-unique sort silently skips or repeats rows at page boundaries without one.
  """
  use Ash.Resource.Preparation

  require Ash.Query
  import Ash.Expr

  @impl true
  def prepare(query, _opts, _context) do
    query
    |> apply_search(Ash.Query.get_argument(query, :search))
    |> apply_difficulty(Ash.Query.get_argument(query, :difficulty))
    |> apply_prep_time(Ash.Query.get_argument(query, :prep_time))
    |> apply_favorites(Ash.Query.get_argument(query, :favorites))
    |> apply_chains(Ash.Query.get_argument(query, :chains))
    |> apply_cuisine(Ash.Query.get_argument(query, :cuisine))
    |> apply_dietary(Ash.Query.get_argument(query, :dietary_needs))
    |> apply_sort(Ash.Query.get_argument(query, :sort_by))
  end

  defp apply_search(query, term) when term in [nil, ""], do: query

  defp apply_search(query, term) do
    Ash.Query.filter(query, ilike(name, ^"%#{term}%"))
  end

  defp apply_difficulty(query, nil), do: query
  defp apply_difficulty(query, level), do: Ash.Query.filter(query, difficulty == ^level)

  # The comparison lives inside the fragment (returning a boolean) rather than in
  # Ash: an Ash-level numeric comparison mis-resolves to money_with_currency (via
  # AshMoney's operator overloads) and fails to cast. Times are integer minutes,
  # so BETWEEN 31 AND 60 is exactly "> 30 and <= 60".
  defp apply_prep_time(query, :quick),
    do:
      Ash.Query.filter(
        query,
        fragment("coalesce(?, 0) + coalesce(?, 0) <= 30", prep_time_minutes, cook_time_minutes)
      )

  defp apply_prep_time(query, :medium),
    do:
      Ash.Query.filter(
        query,
        fragment(
          "coalesce(?, 0) + coalesce(?, 0) BETWEEN 31 AND 60",
          prep_time_minutes,
          cook_time_minutes
        )
      )

  defp apply_prep_time(query, :long),
    do:
      Ash.Query.filter(
        query,
        fragment("coalesce(?, 0) + coalesce(?, 0) > 60", prep_time_minutes, cook_time_minutes)
      )

  defp apply_prep_time(query, _), do: query

  defp apply_favorites(query, true), do: Ash.Query.filter(query, is_favorite == true)
  defp apply_favorites(query, _), do: query

  defp apply_chains(query, true),
    do: Ash.Query.filter(query, is_base_recipe == true or is_follow_up == true)

  defp apply_chains(query, _), do: query

  defp apply_cuisine(query, term) when term in [nil, ""], do: query

  defp apply_cuisine(query, term) do
    Ash.Query.filter(query, ilike(cuisine, ^"%#{term}%"))
  end

  defp apply_dietary(query, needs) when needs in [nil, []], do: query

  defp apply_dietary(query, needs) when is_list(needs) do
    wanted = Enum.map(needs, &to_string/1)
    # Cast both sides to text[]: the column is varchar[], so `varchar[] @> text[]`
    # has no operator without normalising the types.
    Ash.Query.filter(query, fragment("?::text[] @> ?::text[]", dietary_needs, ^wanted))
  end

  defp apply_sort(query, "newest"), do: Ash.Query.sort(query, created_at: :desc, id: :asc)

  defp apply_sort(query, "prep_time") do
    total = calc(^total_time_frag(), type: :integer)
    Ash.Query.sort(query, [{total, :asc}, {:id, :asc}])
  end

  defp apply_sort(query, "difficulty") do
    rank =
      calc(
        fragment(
          "CASE ? WHEN 'easy' THEN 1 WHEN 'medium' THEN 2 WHEN 'hard' THEN 3 ELSE 2 END",
          difficulty
        ),
        type: :integer
      )

    Ash.Query.sort(query, [{rank, :asc}, {:id, :asc}])
  end

  defp apply_sort(query, _), do: Ash.Query.sort(query, name: :asc, id: :asc)

  # Total prep+cook minutes, missing values counted as 0 (Ash has no `coalesce`
  # expr function, so use a Postgres fragment). Composed into the prep_time
  # filters and sort via expression pinning.
  defp total_time_frag do
    # type/2 is required: an untyped fragment makes Ash mis-infer the comparison
    # type (money_with_currency, via AshMoney) and the query fails to cast.
    expr(
      type(
        fragment("coalesce(?, 0) + coalesce(?, 0)", prep_time_minutes, cook_time_minutes),
        :integer
      )
    )
  end
end
