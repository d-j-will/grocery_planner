defmodule GroceryPlannerWeb.MealPlannerLive.PowerLayout do
  @moduledoc """
  Power Mode layout for the Meal Planner.

  Provides a kanban-style week board with drag-and-drop functionality
  for power users who plan their entire week at once.
  """

  use GroceryPlannerWeb, :html

  alias GroceryPlannerWeb.MealPlannerLive.{Terminology, DataLoader}
  import GroceryPlannerWeb.CoreComponents

  def init(socket) do
    # Default mobile_selected_date to the first day of the week (or today if in the week)
    week_start = socket.assigns.week_start
    today = Date.utc_today()

    mobile_selected_date =
      if Date.compare(today, week_start) in [:gt, :eq] and
           Date.compare(today, Date.add(week_start, 6)) in [:lt, :eq] do
        today
      else
        week_start
      end

    socket
    |> Phoenix.Component.assign(:sidebar_open, false)
    |> Phoenix.Component.assign(:selected_meals, MapSet.new())
    |> Phoenix.Component.assign(:pending_swap, nil)
    |> Phoenix.Component.assign(:sidebar_search, "")
    |> Phoenix.Component.assign(:grocery_delta, nil)
    |> Phoenix.Component.assign(:dragging_meal_id, nil)
    |> Phoenix.Component.assign(:dragging_recipe_id, nil)
    |> Phoenix.Component.assign(:mobile_selected_date, mobile_selected_date)
    |> DataLoader.load_all_recipes()
    |> load_sidebar_recipes()
  end

  defp load_sidebar_recipes(socket) do
    # Load favorites (we still load these separately as they might not be in available_recipes if filtered?)
    # Wait, explorer uses available_recipes to find favorites.
    # But for now let's keep loading favorites separately to minimize changes, or unify it.
    # Since ExplorerLayout filters favorites from available_recipes, we can do the same here.

    # We can rely on available_recipes loaded by DataLoader.load_all_recipes
    all_recipes = socket.assigns.available_recipes

    favorites = Enum.filter(all_recipes, & &1.is_favorite)

    socket
    |> Phoenix.Component.assign(:all_sidebar_recipes, all_recipes)
    |> Phoenix.Component.assign(:all_sidebar_favorites, favorites)
    |> Phoenix.Component.assign(:recipes, all_recipes)
    |> Phoenix.Component.assign(:favorites, favorites)
    |> DataLoader.load_recent_recipes()
    |> then(fn s ->
      Phoenix.Component.assign(s, :all_recent_recipes, s.assigns[:recent_recipes] || [])
    end)
  end

  def filter_sidebar_recipes(socket, "") do
    socket
    |> Phoenix.Component.assign(:recipes, socket.assigns[:all_sidebar_recipes] || [])
    |> Phoenix.Component.assign(:favorites, socket.assigns[:all_sidebar_favorites] || [])
    |> Phoenix.Component.assign(
      :recent_recipes,
      socket.assigns[:all_recent_recipes] || socket.assigns[:recent_recipes] || []
    )
  end

  def filter_sidebar_recipes(socket, query) do
    filter_fn = fn recipe -> GroceryPlanner.Recipes.name_matches?(recipe, query) end

    all_recipes = socket.assigns[:all_sidebar_recipes] || []
    all_favorites = socket.assigns[:all_sidebar_favorites] || []
    all_recent = socket.assigns[:all_recent_recipes] || socket.assigns[:recent_recipes] || []

    socket
    |> Phoenix.Component.assign(:recipes, Enum.filter(all_recipes, filter_fn))
    |> Phoenix.Component.assign(:favorites, Enum.filter(all_favorites, filter_fn))
    |> Phoenix.Component.assign(:recent_recipes, Enum.filter(all_recent, filter_fn))
  end

  def render(assigns) do
    ~H"""
    <div
      class="flex flex-col h-[calc(100vh-12rem)] relative"
      id="power-mode-kanban"
      phx-hook="KanbanBoard"
    >
      <%!-- Command Bar --%>
      <div class="bg-base-200 border-b border-base-300 px-4 py-3 rounded-t-xl">
        <div class="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-3">
          <%!-- Week Navigation --%>
          <div class="hidden lg:flex items-center gap-2">
            <button phx-click="prev_week" class="btn btn-ghost btn-sm" id="power-prev-week">
              <.icon name="hero-chevron-left" class="w-4 h-4" /> Prev
            </button>
            <span class="font-semibold text-lg min-w-[180px] text-center">
              {format_week_range(@week_start)}
            </span>
            <button phx-click="next_week" class="btn btn-ghost btn-sm" id="power-next-week">
              Next <.icon name="hero-chevron-right" class="w-4 h-4" />
            </button>
            <button phx-click="today" class="btn btn-primary btn-sm" id="power-today">
              This week
            </button>
          </div>

          <%!-- Bulk Actions --%>
          <div class="flex items-center gap-2 flex-wrap">
            <button
              class="btn btn-outline btn-sm"
              phx-click="copy_last_week"
              title="Copy meals from last week"
            >
              <.icon name="hero-document-duplicate" class="w-4 h-4" />
              <span class="hidden sm:inline">Copy Last Week</span>
            </button>
            <button
              class="btn btn-outline btn-sm"
              phx-click="auto_fill_week"
              title="Auto-fill empty slots"
            >
              <.icon name="hero-sparkles" class="w-4 h-4" />
              <span class="hidden sm:inline">Auto-fill</span>
            </button>
            <button
              class="btn btn-outline btn-sm text-error hover:btn-error"
              phx-click="clear_week"
              data-confirm="Are you sure you want to clear all meals this week?"
              title="Clear all meals this week"
            >
              <.icon name="hero-trash" class="w-4 h-4" />
              <span class="hidden sm:inline">Clear Week</span>
            </button>
            <div class="divider divider-horizontal mx-1 hidden sm:flex"></div>
            <button
              class="btn btn-ghost btn-sm btn-square"
              phx-click="toggle_sidebar"
              title={if @sidebar_open, do: "Hide recipe sidebar", else: "Show recipe sidebar"}
            >
              <.icon
                name={if @sidebar_open, do: "hero-x-mark", else: "hero-bars-3"}
                class="w-4 h-4"
              />
            </button>
          </div>
        </div>

        <%!-- Selection & Shopping Summary --%>
        <div class="flex items-center justify-between mt-2 text-sm">
          <div class="flex items-center gap-4">
            <%= if MapSet.size(@selected_meals) > 0 do %>
              <span class="badge badge-primary">
                {MapSet.size(@selected_meals)} selected
              </span>
              <button class="link link-primary text-xs" phx-click="delete_selected">
                Delete selected
              </button>
              <button class="link text-xs" phx-click="clear_selection">
                Clear selection
              </button>
            <% end %>
          </div>

          <div class="flex items-center gap-2">
            <.icon name="hero-shopping-cart" class="w-4 h-4" />
            <%= if length(@week_shopping_items || []) > 0 do %>
              <span>{length(@week_shopping_items)} items needed</span>
              <button class="btn btn-primary btn-xs" phx-click="generate_shopping_list">
                Generate List
              </button>
            <% else %>
              <span class="text-success">All ingredients available!</span>
            <% end %>
          </div>
        </div>
      </div>

      <%!-- Main Content: Kanban Board + Sidebar --%>
      <div class="flex flex-1 overflow-hidden">
        <%!-- Kanban Board --%>
        <div class="flex-1 overflow-y-auto lg:overflow-hidden" id="power-week-board">
          <%!-- Desktop: Full Week Grid --%>
          <div class="hidden lg:flex lg:flex-row lg:h-full h-auto gap-2 p-2 lg:min-w-[900px] lg:overflow-x-auto power-week-grid">
            <%= for day <- @days do %>
              <.day_column
                day={day}
                week_meals={@week_meals}
                selected_meals={@selected_meals}
              />
            <% end %>
          </div>

          <%!-- Mobile: Single-Day Pager --%>
          <div class="lg:hidden flex flex-col h-full">
            <%!-- Mobile Day Navigation --%>
            <.mobile_day_nav
              mobile_selected_date={@mobile_selected_date}
              week_start={@week_start}
              days={@days}
            />

            <%!-- Mobile Day Content --%>
            <div class="flex-1 overflow-y-auto p-3">
              <.day_column
                day={@mobile_selected_date}
                week_meals={@week_meals}
                selected_meals={@selected_meals}
                mobile={true}
              />
            </div>
          </div>
        </div>

        <%!-- Recipe Sidebar --%>
        <div class={[
          "bg-base-100 transition-all duration-300 overflow-hidden flex-shrink-0 z-20 absolute right-0 h-full shadow-xl lg:relative lg:shadow-none",
          if(@sidebar_open, do: "w-72 border-l border-base-300", else: "w-0 border-l-0")
        ]}>
          <div class="w-72 h-full flex flex-col absolute right-0 top-0">
            <.recipe_sidebar
              :if={true}
              recipes={@recipes}
              favorites={@favorites}
              recent_recipes={@recent_recipes}
              sidebar_search={assigns[:sidebar_search] || ""}
            />
          </div>
        </div>
      </div>

      <%!-- Swap Confirmation Modal --%>
      <.swap_confirmation_modal :if={@pending_swap} swap={@pending_swap} week_meals={@week_meals} />

      <%!-- Keyboard Shortcuts Help (hidden, for accessibility) --%>
      <div class="sr-only">
        Keyboard shortcuts: Ctrl+Z to undo, Ctrl+Shift+Z to redo, Delete to remove selected,
        Escape to clear selection, Ctrl+Arrow to navigate weeks
      </div>

      <%!-- Grocery Delta Toast (shown during drag) --%>
      <%= if @grocery_delta && (@grocery_delta.added_count > 0 || @grocery_delta.removed_count > 0) do %>
        <div
          class="fixed bottom-4 left-1/2 -translate-x-1/2 z-50 pointer-events-none animate-fade-in"
          role="status"
          aria-live="polite"
        >
          <div class="bg-base-100 rounded-lg shadow-2xl px-5 py-3 flex items-center gap-4 border border-base-300">
            <.icon name="hero-shopping-cart" class="w-5 h-5 text-base-content/60" />
            <div class="flex items-center gap-3 font-medium">
              <%= if @grocery_delta.added_count > 0 do %>
                <span class="text-warning flex items-center gap-1">
                  <.icon name="hero-plus" class="w-4 h-4" />
                  {@grocery_delta.added_count}
                  {if @grocery_delta.added_count == 1, do: "item", else: "items"}
                </span>
              <% end %>
              <%= if @grocery_delta.removed_count > 0 do %>
                <span class="text-success flex items-center gap-1">
                  <.icon name="hero-minus" class="w-4 h-4" />
                  {@grocery_delta.removed_count}
                  {if @grocery_delta.removed_count == 1, do: "item", else: "items"}
                </span>
              <% end %>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  defp mobile_day_nav(assigns) do
    week_end = Date.add(assigns.week_start, 6)
    is_first_day = Date.compare(assigns.mobile_selected_date, assigns.week_start) == :eq
    is_last_day = Date.compare(assigns.mobile_selected_date, week_end) == :eq

    assigns =
      assigns
      |> assign(:is_first_day, is_first_day)
      |> assign(:is_last_day, is_last_day)

    ~H"""
    <div class="bg-base-200 border-b border-base-300 px-3 py-2">
      <%!-- Day Pills / Week Strip --%>
      <div class="flex items-center justify-center gap-1 mb-3">
        <%= for day <- @days do %>
          <button
            phx-click="power_mobile_select_day"
            phx-value-date={Date.to_iso8601(day)}
            class={[
              "w-11 h-11 rounded-full text-xs font-semibold transition-all",
              Date.compare(day, @mobile_selected_date) == :eq &&
                "bg-primary text-primary-content shadow-md",
              Date.compare(day, @mobile_selected_date) != :eq &&
                Date.compare(day, Date.utc_today()) == :eq &&
                "bg-primary/20 text-primary ring-1 ring-primary/50",
              Date.compare(day, @mobile_selected_date) != :eq &&
                Date.compare(day, Date.utc_today()) != :eq &&
                "bg-base-100 text-base-content/70 hover:bg-base-300"
            ]}
          >
            {Calendar.strftime(day, "%a") |> String.slice(0, 1)}
          </button>
        <% end %>
      </div>

      <%!-- Prev/Next Navigation --%>
      <div class="flex items-center justify-between">
        <button
          phx-click="power_mobile_prev_day"
          disabled={@is_first_day}
          class={[
            "btn btn-ghost gap-1 min-h-[44px] min-w-[44px]",
            @is_first_day && "opacity-40 cursor-not-allowed"
          ]}
        >
          <.icon name="hero-chevron-left" class="w-4 h-4" /> Prev
        </button>

        <div class="text-center">
          <div class="font-bold text-lg">
            {Calendar.strftime(@mobile_selected_date, "%A")}
          </div>
          <div class="text-xs text-base-content/60">
            {Calendar.strftime(@mobile_selected_date, "%B %d, %Y")}
          </div>
        </div>

        <button
          phx-click="power_mobile_next_day"
          disabled={@is_last_day}
          class={[
            "btn btn-ghost gap-1 min-h-[44px] min-w-[44px]",
            @is_last_day && "opacity-40 cursor-not-allowed"
          ]}
        >
          Next <.icon name="hero-chevron-right" class="w-4 h-4" />
        </button>
      </div>
    </div>
    """
  end

  defp day_column(assigns) do
    meal_count =
      Enum.count(assigns.week_meals[assigns.day] || %{}, fn {_type, meal} -> meal != nil end)

    mobile = Map.get(assigns, :mobile, false)

    assigns =
      assigns
      |> assign(:meal_count, meal_count)
      |> assign(:mobile, mobile)

    ~H"""
    <div class={[
      "flex-1 min-w-[120px] overflow-hidden flex flex-col w-full",
      !@mobile && "lg:w-auto",
      !@mobile && "lg:rounded-xl lg:border lg:border-base-200 lg:bg-base-100 lg:shadow-sm",
      !@mobile && "max-lg:border-b max-lg:border-base-200/80 max-lg:pb-3",
      !@mobile && Date.compare(@day, Date.utc_today()) == :eq && "lg:ring-2 lg:ring-primary/30",
      @mobile && "rounded-xl border border-base-200 bg-base-100 shadow-sm",
      @mobile && Date.compare(@day, Date.utc_today()) == :eq && "ring-2 ring-primary/30"
    ]}>
      <%!-- Day Header (hidden on mobile pager since we have nav above) --%>
      <div class={[
        "px-3 py-2 flex items-center justify-between gap-2 flex-shrink-0",
        "border-b",
        @mobile && "hidden",
        if(Date.compare(@day, Date.utc_today()) == :eq,
          do: "bg-primary text-primary-content border-transparent",
          else: "bg-base-200 text-base-content border-base-200"
        )
      ]}>
        <div class="min-w-0">
          <div class="text-sm font-bold truncate">
            {Calendar.strftime(@day, "%a")}
          </div>
          <div class={[
            "text-xs",
            Date.compare(@day, Date.utc_today()) == :eq && "opacity-80",
            Date.compare(@day, Date.utc_today()) != :eq && "text-base-content/60"
          ]}>
            {Calendar.strftime(@day, "%b %d")}
          </div>
        </div>
        <div class={[
          "w-7 h-7 rounded-lg flex items-center justify-center text-xs font-bold",
          @meal_count == 0 && "bg-base-100/40 text-base-content/50",
          @meal_count > 0 &&
            if(Date.compare(@day, Date.utc_today()) == :eq,
              do: "bg-primary-content/20 text-primary-content",
              else: "bg-primary/20 text-primary"
            )
        ]}>
          {@meal_count}
        </div>
      </div>

      <%!-- Meal Slots --%>
      <div class={[
        "flex-1 overflow-y-auto p-2",
        @mobile && "space-y-3",
        !@mobile && "space-y-2"
      ]}>
        <%= for meal_type <- [:breakfast, :lunch, :dinner, :snack] do %>
          <.meal_slot
            day={@day}
            meal_type={meal_type}
            meal={get_meal_plan(@day, meal_type, @week_meals)}
            selected_meals={@selected_meals}
            mobile={@mobile}
          />
        <% end %>
      </div>
    </div>
    """
  end

  defp meal_slot(assigns) do
    mobile = Map.get(assigns, :mobile, false)
    assigns = assign(assigns, :mobile, mobile)

    ~H"""
    <div
      class={[
        "rounded-lg transition-all duration-200 border-2 border-dashed border-transparent hover:border-base-300",
        @mobile && "p-2 min-h-[70px]",
        !@mobile && "p-1.5 min-h-[52px]"
      ]}
      data-drop-zone
      data-date={Date.to_iso8601(@day)}
      data-meal-type={@meal_type}
    >
      <div class={[
        "uppercase text-base-content/50 mb-1 px-1 flex items-center gap-1",
        @mobile && "text-xs",
        !@mobile && "text-[10px]"
      ]}>
        <span class={["leading-none", @mobile && "text-base", !@mobile && "text-sm"]}>
          {Terminology.meal_type_icon(@meal_type) |> Terminology.icon_to_emoji()}
        </span>
        <span class="capitalize">{@meal_type}</span>
      </div>

      <%= if @meal do %>
        <.meal_card
          meal={@meal}
          selected={MapSet.member?(@selected_meals, @meal.id)}
          mobile={@mobile}
        />
      <% else %>
        <button
          phx-click="add_meal"
          phx-value-date={@day}
          phx-value-meal_type={@meal_type}
          class={[
            "w-full rounded-lg border border-dashed border-base-300 text-base-content/30 hover:border-primary hover:text-primary hover:bg-primary/5 transition-colors flex items-center justify-center gap-1",
            @mobile && "h-14 text-sm",
            !@mobile && "h-9 text-xs"
          ]}
        >
          <.icon name="hero-plus" class="w-4 h-4" /> Add
        </button>
      <% end %>
    </div>
    """
  end

  defp meal_card(assigns) do
    mobile = Map.get(assigns, :mobile, false)
    assigns = assign(assigns, :mobile, mobile)

    ~H"""
    <div
      class={[
        "bg-base-100 rounded-lg shadow-sm cursor-grab active:cursor-grabbing group border border-base-200 hover:border-primary/30 hover:shadow-md transition-all touch-manipulation",
        @selected && "ring-2 ring-primary bg-primary/5",
        @mobile && "p-3",
        !@mobile && "p-2"
      ]}
      data-draggable="meal"
      data-meal-id={@meal.id}
      data-date={Date.to_iso8601(@meal.scheduled_date)}
      data-meal-type={@meal.meal_type}
    >
      <div class="flex items-start justify-between gap-1">
        <div class="flex-1 min-w-0">
          <p class={["font-medium truncate", @mobile && "text-sm", !@mobile && "text-xs"]}>
            {@meal.recipe.name}
          </p>
          <p class={["text-base-content/50 mt-0.5", @mobile && "text-xs", !@mobile && "text-[10px]"]}>
            {@meal.servings} srv • {get_total_time(@meal.recipe)} min
          </p>
        </div>

        <%!-- Selection checkbox (always visible on mobile, hover on desktop) --%>
        <input
          type="checkbox"
          class={[
            "checkbox checkbox-primary transition-opacity",
            @mobile && "checkbox-md opacity-100",
            !@mobile && "checkbox-xs opacity-0 group-hover:opacity-100"
          ]}
          checked={@selected}
          phx-click="toggle_meal_selection"
          phx-value-meal-id={@meal.id}
        />
      </div>

      <%!-- Availability indicator --%>
      <div class={["flex items-center gap-1", @mobile && "mt-2", !@mobile && "mt-1.5"]}>
        <%= if recipe_ready?(@meal.recipe) do %>
          <span class={["badge badge-success gap-0.5", @mobile && "badge-sm", !@mobile && "badge-xs"]}>
            <.icon name="hero-check" class="w-3 h-3" /> Ready
          </span>
        <% else %>
          <span class={["badge badge-warning gap-0.5", @mobile && "badge-sm", !@mobile && "badge-xs"]}>
            <.icon name="hero-shopping-cart" class="w-3 h-3" /> Need items
          </span>
        <% end %>
      </div>

      <%!-- Quick actions (always visible on mobile, hover on desktop) --%>
      <div class={[
        "mt-2 pt-2 border-t border-base-200 flex items-center gap-1",
        @mobile && "opacity-100",
        !@mobile && "opacity-0 group-hover:opacity-100 transition-opacity"
      ]}>
        <button
          phx-click="edit_meal"
          phx-value-id={@meal.id}
          class={["btn btn-ghost flex-1", @mobile && "btn-sm", !@mobile && "btn-xs"]}
          title="Edit"
        >
          <.icon name="hero-pencil-square" class={if @mobile, do: "w-4 h-4", else: "w-3 h-3"} />
        </button>
        <button
          phx-click="remove_meal"
          phx-value-id={@meal.id}
          class={["btn btn-ghost text-error flex-1", @mobile && "btn-sm", !@mobile && "btn-xs"]}
          title="Remove"
        >
          <.icon name="hero-trash" class={if @mobile, do: "w-4 h-4", else: "w-3 h-3"} />
        </button>
      </div>
    </div>
    """
  end

  defp recipe_sidebar(assigns) do
    ~H"""
    <div class="w-72 h-full flex flex-col" data-recipe-sidebar>
      <%!-- Search --%>
      <div class="p-3 border-b border-base-300">
        <div class="relative">
          <input
            type="text"
            placeholder="Search recipes..."
            class="input input-bordered input-sm w-full pl-8"
            value={@sidebar_search}
            phx-change="search_sidebar"
            phx-debounce="200"
            name="query"
          />
          <.icon
            name="hero-magnifying-glass"
            class="w-4 h-4 absolute left-2.5 top-1/2 -translate-y-1/2 text-base-content/50"
          />
        </div>
        <p class="text-xs text-base-content/50 mt-2">
          Drag recipes to the board to add them
        </p>
      </div>

      <%!-- Recipe Lists --%>
      <div class="flex-1 overflow-y-auto p-3 space-y-4">
        <%!-- Favorites --%>
        <%= if @favorites && @favorites != [] do %>
          <div>
            <h4 class="text-xs font-bold uppercase text-base-content/60 mb-2 flex items-center gap-1">
              <.icon name="hero-heart" class="w-3 h-3" /> Favorites
            </h4>
            <div class="space-y-1" data-recipe-list>
              <%= for recipe <- @favorites do %>
                <.sidebar_recipe_card recipe={recipe} />
              <% end %>
            </div>
          </div>
        <% end %>

        <%!-- Recent --%>
        <%= if @recent_recipes && @recent_recipes != [] do %>
          <div>
            <h4 class="text-xs font-bold uppercase text-base-content/60 mb-2 flex items-center gap-1">
              <.icon name="hero-clock" class="w-3 h-3" /> Recent
            </h4>
            <div class="space-y-1" data-recipe-list>
              <%= for recipe <- Enum.take(@recent_recipes, 5) do %>
                <.sidebar_recipe_card recipe={recipe} />
              <% end %>
            </div>
          </div>
        <% end %>

        <%!-- All Recipes --%>
        <div>
          <h4 class="text-xs font-bold uppercase text-base-content/60 mb-2 flex items-center gap-1">
            <.icon name="hero-book-open" class="w-3 h-3" /> All Recipes
          </h4>
          <div class="space-y-1" data-recipe-list>
            <%= for recipe <- @recipes || [] do %>
              <.sidebar_recipe_card recipe={recipe} />
            <% end %>
            <%= if (@recipes || []) == [] do %>
              <p class="text-xs text-base-content/50 text-center py-4">
                No recipes found
              </p>
            <% end %>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp sidebar_recipe_card(assigns) do
    ~H"""
    <div
      class="bg-base-200 rounded-lg p-2 cursor-grab active:cursor-grabbing hover:bg-base-300 transition-colors"
      data-draggable="recipe"
      data-recipe-id={@recipe.id}
    >
      <div class="flex items-center gap-2">
        <%= if @recipe.image_url do %>
          <img src={@recipe.image_url} class="w-8 h-8 rounded object-cover flex-shrink-0" />
        <% else %>
          <div class="w-8 h-8 rounded bg-base-300 flex items-center justify-center flex-shrink-0">
            <.icon name="hero-photo" class="w-4 h-4 text-base-content/30" />
          </div>
        <% end %>
        <div class="flex-1 min-w-0">
          <p class="text-sm font-medium truncate">{@recipe.name}</p>
          <p class="text-xs text-base-content/50">{get_total_time(@recipe)} min</p>
        </div>
      </div>
    </div>
    """
  end

  defp swap_confirmation_modal(assigns) do
    # Get the names for both meals
    dragged_meal = get_meal_by_id(assigns.swap.dragged_meal_id, assigns.week_meals)
    target_meal = get_meal_by_id(assigns.swap.target_meal_id, assigns.week_meals)

    assigns =
      assigns
      |> assign(:dragged_meal, dragged_meal)
      |> assign(:target_meal, target_meal)

    ~H"""
    <div class="modal modal-open">
      <div class="modal-box max-w-sm">
        <h3 class="font-bold text-lg mb-4">Swap Meals?</h3>

        <div class="space-y-3">
          <div class="flex items-center gap-3 p-3 bg-base-200 rounded-lg">
            <div class="badge badge-primary badge-sm">Moving</div>
            <span class="font-medium truncate">
              {if @dragged_meal, do: @dragged_meal.recipe.name, else: "Unknown"}
            </span>
          </div>

          <div class="flex justify-center">
            <.icon name="hero-arrows-up-down" class="w-5 h-5 text-base-content/50" />
          </div>

          <div class="flex items-center gap-3 p-3 bg-base-200 rounded-lg">
            <div class="badge badge-secondary badge-sm">Target</div>
            <span class="font-medium truncate">
              {if @target_meal, do: @target_meal.recipe.name, else: "Unknown"}
            </span>
          </div>
        </div>

        <p class="text-sm text-base-content/70 mt-4">
          The two meals will swap positions.
        </p>

        <div class="modal-action">
          <button class="btn btn-ghost" phx-click="cancel_swap">
            Cancel
          </button>
          <button class="btn btn-primary" phx-click="confirm_swap">
            <.icon name="hero-arrows-up-down" class="w-4 h-4" /> Swap
          </button>
        </div>
      </div>
      <div class="modal-backdrop bg-black/50" phx-click="cancel_swap"></div>
    </div>
    """
  end

  # Helper functions

  defp get_meal_plan(date, meal_type, week_meals) do
    week_meals
    |> Map.get(date, %{})
    |> Map.get(meal_type)
  end

  defp get_meal_by_id(meal_id, week_meals) do
    week_meals
    |> Map.values()
    |> Enum.flat_map(&Map.values/1)
    |> Enum.find(&(&1 && &1.id == meal_id))
  end

  defp recipe_ready?(recipe) do
    # Check if recipe has can_make field, otherwise assume ready
    Map.get(recipe, :can_make, true)
  end

  defp get_total_time(recipe) do
    case Map.get(recipe, :total_time_minutes) do
      %Ash.NotLoaded{} -> "?"
      nil -> "?"
      time -> time
    end
  end

  defp format_week_range(week_start) do
    week_end = Date.add(week_start, 6)
    start_str = Calendar.strftime(week_start, "%b %d")
    end_str = Calendar.strftime(week_end, "%b %d")
    "#{start_str} - #{end_str}"
  end

  # Event handlers for mobile day navigation

  def handle_event("power_mobile_select_day", %{"date" => date_str}, socket) do
    {:ok, date} = Date.from_iso8601(date_str)
    {:noreply, Phoenix.Component.assign(socket, :mobile_selected_date, date)}
  end

  def handle_event("power_mobile_prev_day", _params, socket) do
    current = socket.assigns.mobile_selected_date
    week_start = socket.assigns.week_start

    new_date =
      if Date.compare(current, week_start) == :gt do
        Date.add(current, -1)
      else
        current
      end

    {:noreply, Phoenix.Component.assign(socket, :mobile_selected_date, new_date)}
  end

  def handle_event("power_mobile_next_day", _params, socket) do
    current = socket.assigns.mobile_selected_date
    week_end = Date.add(socket.assigns.week_start, 6)

    new_date =
      if Date.compare(current, week_end) == :lt do
        Date.add(current, 1)
      else
        current
      end

    {:noreply, Phoenix.Component.assign(socket, :mobile_selected_date, new_date)}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}
end
