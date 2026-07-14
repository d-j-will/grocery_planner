defmodule GroceryPlannerWeb.MealPlannerLive.ExplorerLayout do
  use GroceryPlannerWeb, :html

  import Phoenix.LiveView, only: [put_flash: 3]
  alias GroceryPlannerWeb.MealPlannerLive.{DataLoader, Terminology}
  import GroceryPlannerWeb.CoreComponents

  # Built-in system presets available to all users
  @system_presets [
    %{
      id: "system-weeknight-quick-wins",
      name: "Weeknight Quick Wins",
      system?: true,
      criteria: %{
        "search" => "",
        "filter" => "quick",
        "difficulty" => "easy",
        "cuisine" => "",
        "dietary_needs" => []
      }
    },
    %{
      id: "system-mediterranean",
      name: "Mediterranean",
      system?: true,
      criteria: %{
        "search" => "",
        "filter" => "",
        "difficulty" => "",
        "cuisine" => "Mediterranean",
        "dietary_needs" => []
      }
    },
    %{
      id: "system-healthy-quick",
      name: "Healthy & Quick",
      system?: true,
      criteria: %{
        "search" => "",
        "filter" => "quick",
        "difficulty" => "",
        "cuisine" => "",
        "dietary_needs" => [:vegetarian]
      }
    }
  ]

  def system_presets, do: @system_presets

  # Initialize explorer-specific state
  def init(socket) do
    socket
    |> assign(:explorer_search, "")
    |> assign(:explorer_filter, "")
    |> assign(:explorer_difficulty, "")
    |> assign(:explorer_cuisine, "")
    |> assign(:explorer_dietary_needs, [])
    |> assign(:explorer_sort, "name")
    |> assign(:explorer_recipes, [])
    |> assign(:explorer_favorite_recipes, [])
    |> assign(:explorer_recent_recipes, [])
    |> assign(:show_explorer_slot_picker, false)
    |> assign(:explorer_picking_recipe, nil)
    |> assign(:explorer_selected_slot, nil)
    |> assign(:expanded_day, Date.utc_today())
    # Filter presets (user presets + system presets)
    |> assign(:filter_presets, [])
    |> assign(:system_presets, @system_presets)
    |> assign(:selected_preset_id, nil)
    |> assign(:show_save_preset_modal, false)
    |> assign(:preset_name_input, "")
    # Mobile filter bottom sheet
    |> assign(:show_mobile_filter_sheet, false)
    |> load_filter_presets()
    |> DataLoader.load_all_recipes()
    |> load_explorer_recipes()
  end

  defp load_filter_presets(socket) do
    case GroceryPlanner.Recipes.list_filter_presets(
           actor: socket.assigns.current_user,
           authorize?: true
         ) do
      {:ok, presets} ->
        assign(socket, :filter_presets, presets)

      {:error, _} ->
        assign(socket, :filter_presets, [])
    end
  end

  def render(assigns) do
    ~H"""
    <div>
      <!-- Mobile Layout (< 1024px) -->
      <div class="flex flex-col h-[calc(100vh-8rem)] lg:hidden">
        <.mobile_header explorer_search={@explorer_search} />

        <.mobile_week_strip
          week_start={@week_start}
          days={@days}
          week_meals={@week_meals}
          expanded_day={@expanded_day}
        />

        <.mobile_expanded_day
          :if={@expanded_day}
          day={@expanded_day}
          week_meals={@week_meals}
          available_recipes={@available_recipes}
          favorites={@explorer_favorite_recipes}
          recents={@explorer_recent_recipes}
        />

        <.mobile_filter_bar
          explorer_filter={@explorer_filter}
          explorer_difficulty={@explorer_difficulty}
          explorer_search={@explorer_search}
          explorer_cuisine={@explorer_cuisine}
          explorer_dietary_needs={@explorer_dietary_needs}
          explorer_sort={@explorer_sort}
          filter_presets={@filter_presets}
          system_presets={@system_presets}
          selected_preset_id={@selected_preset_id}
        />

        <%!-- Mobile Filter Bottom Sheet --%>
        <.mobile_filter_sheet
          :if={@show_mobile_filter_sheet}
          explorer_filter={@explorer_filter}
          explorer_difficulty={@explorer_difficulty}
          explorer_cuisine={@explorer_cuisine}
          explorer_dietary_needs={@explorer_dietary_needs}
          explorer_sort={@explorer_sort}
          filter_presets={@filter_presets}
          system_presets={@system_presets}
          selected_preset_id={@selected_preset_id}
        />
        
    <!-- Mobile Recipe Feed -->
        <div class="flex-1 overflow-y-auto p-3" id="mobile-explorer-feed">
          <%= if @explorer_recipes == [] && @explorer_favorite_recipes == [] && @explorer_recent_recipes == [] do %>
            <.empty_state_message
              search={@explorer_search}
              filter={@explorer_filter}
              difficulty={@explorer_difficulty}
              id_prefix="mobile"
            />
          <% else %>
            <div class="space-y-6 pb-20">
              <%= if @explorer_favorite_recipes != [] do %>
                <section>
                  <h3 class="font-bold text-sm mb-2 px-1">Favorites</h3>
                  <div class="grid grid-cols-2 gap-3">
                    <%= for recipe <- Enum.take(@explorer_favorite_recipes, 4) do %>
                      <.explorer_recipe_card recipe={recipe} id_prefix="mob-fav" compact={true} />
                    <% end %>
                  </div>
                </section>
              <% end %>

              <section>
                <h3 class="font-bold text-sm mb-2 px-1">All Recipes</h3>
                <div class="grid grid-cols-2 gap-3">
                  <%= for recipe <- @explorer_recipes do %>
                    <.explorer_recipe_card recipe={recipe} id_prefix="mob-feed" compact={true} />
                  <% end %>
                </div>
              </section>
            </div>
          <% end %>
        </div>
      </div>
      
    <!-- Desktop Layout (>= 1024px) -->
      <div class="hidden lg:grid gap-6 lg:grid-cols-[380px_1fr]">
        <!-- Left Column: Weekly Plan Timeline -->
        <div class="bg-base-100 rounded-2xl shadow-sm border border-base-200 overflow-hidden h-[calc(100vh-10rem)] flex flex-col">
          <div class="p-5 border-b border-base-200 bg-gradient-to-b from-base-100 to-base-200/40 shrink-0">
            <div class="flex items-start justify-between gap-3">
              <div>
                <h2 class="text-lg font-bold text-base-content">Your week</h2>
                <p class="text-sm text-base-content/60">
                  Tap a slot, then add from the feed.
                </p>
              </div>
              <div class="flex items-center gap-2">
                <button phx-click="today" class="btn btn-primary btn-sm">Today</button>
              </div>
            </div>

            <div class="mt-4 flex items-center gap-2">
              <button
                phx-click="prev_week"
                class="btn btn-ghost btn-sm"
                title="Previous week"
              >
                <.icon name="hero-chevron-left" class="w-4 h-4" />
              </button>
              <div class="flex-1 text-center text-sm font-semibold text-base-content">
                {Calendar.strftime(@week_start, "%b %d")} – {Calendar.strftime(
                  Date.add(@week_start, 6),
                  "%b %d"
                )}
              </div>
              <button
                phx-click="next_week"
                class="btn btn-ghost btn-sm"
                title="Next week"
              >
                <.icon name="hero-chevron-right" class="w-4 h-4" />
              </button>
            </div>
          </div>

          <div class="p-4 overflow-y-auto flex-1" id="explorer-timeline">
            <div class="space-y-4">
              <%= for day <- @days do %>
                <div class="rounded-xl border border-base-200/80 overflow-hidden">
                  <div class={[
                    "px-4 py-3 flex items-center justify-between",
                    if(Date.compare(day, Date.utc_today()) == :eq,
                      do: "bg-primary text-primary-content",
                      else: "bg-base-200 text-base-content"
                    )
                  ]}>
                    <div class="font-semibold">
                      {Calendar.strftime(day, "%a")}
                      <span class="opacity-70 font-normal">
                        {Calendar.strftime(day, "%b %d")}
                      </span>
                    </div>
                    <div class="text-xs font-semibold opacity-80">
                      <% meal_count =
                        Enum.count(@meal_plans, fn mp ->
                          mp.scheduled_date == day
                        end) %>
                      <%= if meal_count == 0 do %>
                        No meals
                      <% else %>
                        {meal_count} {if meal_count == 1, do: "meal", else: "meals"}
                      <% end %>
                    </div>
                  </div>

                  <div class="p-3 grid grid-cols-1 gap-2">
                    <%= for meal_type <- [:breakfast, :lunch, :dinner, :snack] do %>
                      <.desktop_meal_slot
                        day={day}
                        meal_type={meal_type}
                        week_meals={@week_meals}
                        explorer_selected_slot={@explorer_selected_slot}
                        available_recipes={@available_recipes}
                        favorites={@explorer_favorite_recipes}
                        recents={@explorer_recent_recipes}
                      />
                    <% end %>
                  </div>
                </div>
              <% end %>
            </div>
          </div>
        </div>
        
    <!-- Right Column: Explorer Feed -->
        <div class="bg-base-100 rounded-2xl shadow-sm border border-base-200 overflow-hidden h-[calc(100vh-10rem)] flex flex-col">
          <div class="p-5 border-b border-base-200 bg-gradient-to-b from-base-100 to-base-200/40 shrink-0">
            <div class="flex items-start justify-between gap-4">
              <div>
                <h2 class="text-lg font-bold text-base-content">Explore recipes</h2>
                <p class="text-sm text-base-content/60">
                  Discover something new, then add it to your plan.
                </p>
              </div>
              <.link navigate={~p"/recipes/search"} class="btn btn-ghost btn-sm">
                Browse
              </.link>
            </div>

            <div class="mt-4">
              <div class="flex items-center gap-2">
                <div class="relative flex-1">
                  <.icon
                    name="hero-magnifying-glass"
                    class="w-5 h-5 absolute left-3 top-1/2 -translate-y-1/2 text-base-content/40"
                  />
                  <input
                    id="explorer-recipe-search"
                    type="text"
                    name="explorer_search"
                    value={@explorer_search}
                    placeholder="Search recipes..."
                    phx-keyup="explorer_search"
                    phx-debounce="250"
                    class="input w-full pl-10"
                  />
                </div>

                <button
                  :if={has_active_filters?(assigns)}
                  phx-click="explorer_clear_filters"
                  class="btn btn-ghost btn-sm whitespace-nowrap"
                  id="explorer-clear-filters-top"
                  title="Clear Explorer filters"
                >
                  Clear filters
                </button>
              </div>
            </div>
            
    <!-- Presets Row -->
            <div class="mt-3 flex items-center gap-2">
              <div class="dropdown">
                <label tabindex="0" class="btn btn-sm btn-outline gap-1">
                  <.icon name="hero-bookmark" class="w-4 h-4" />
                  <%= if @selected_preset_id do %>
                    <% preset = find_preset(@selected_preset_id, @filter_presets, @system_presets) %>
                    {(preset && preset.name) || "Presets"}
                  <% else %>
                    Presets
                  <% end %>
                  <.icon name="hero-chevron-down" class="w-3 h-3" />
                </label>
                <ul
                  tabindex="0"
                  class="dropdown-content z-20 menu p-2 shadow-lg bg-base-100 rounded-box w-56 border border-base-200"
                >
                  <%!-- System presets section --%>
                  <li class="menu-title text-[10px] uppercase tracking-wider text-base-content/50 pt-1">
                    Built-in
                  </li>
                  <%= for preset <- @system_presets do %>
                    <li>
                      <button
                        phx-click="explorer_load_preset"
                        phx-value-preset_id={preset.id}
                        phx-value-system="true"
                        class={[
                          "text-left",
                          @selected_preset_id == preset.id && "font-semibold text-primary"
                        ]}
                      >
                        <.icon name="hero-sparkles" class="w-3.5 h-3.5 opacity-50" />
                        {preset.name}
                      </button>
                    </li>
                  <% end %>

                  <%!-- User presets section --%>
                  <%= if @filter_presets != [] do %>
                    <li class="menu-title text-[10px] uppercase tracking-wider text-base-content/50 pt-2 mt-1 border-t border-base-200">
                      My Presets
                    </li>
                    <%= for preset <- @filter_presets do %>
                      <li>
                        <div class="flex items-center justify-between gap-2 w-full">
                          <button
                            phx-click="explorer_load_preset"
                            phx-value-preset_id={preset.id}
                            class={[
                              "flex-1 text-left truncate",
                              @selected_preset_id == preset.id && "font-semibold text-primary"
                            ]}
                          >
                            {preset.name}
                          </button>
                          <button
                            phx-click="explorer_delete_preset"
                            phx-value-preset_id={preset.id}
                            class="btn btn-ghost btn-xs text-error/60 hover:text-error"
                            title="Delete preset"
                          >
                            <.icon name="hero-trash" class="w-3 h-3" />
                          </button>
                        </div>
                      </li>
                    <% end %>
                  <% end %>
                </ul>
              </div>

              <button
                :if={has_active_filters?(assigns)}
                phx-click="explorer_open_save_preset"
                class="btn btn-sm btn-ghost gap-1"
                id="explorer-save-preset-btn"
              >
                <.icon name="hero-bookmark-square" class="w-4 h-4" /> Save
              </button>
            </div>

            <div class="mt-3 flex flex-wrap gap-2">
              <button
                phx-click="explorer_filter"
                phx-value-filter="quick"
                class={[
                  "btn btn-sm",
                  if(@explorer_filter == "quick", do: "btn-primary", else: "btn-ghost")
                ]}
                id="explorer-filter-quick"
              >
                Under 30 min
              </button>
              <button
                phx-click="explorer_filter"
                phx-value-filter="pantry"
                class={[
                  "btn btn-sm",
                  if(@explorer_filter == "pantry", do: "btn-primary", else: "btn-ghost")
                ]}
                id="explorer-filter-pantry"
              >
                Pantry-first
              </button>
              <button
                phx-click="explorer_filter"
                phx-value-filter=""
                class={[
                  "btn btn-sm",
                  if(@explorer_filter in [nil, ""], do: "btn-primary", else: "btn-ghost")
                ]}
                id="explorer-filter-all"
              >
                All
              </button>
            </div>

            <div class="mt-2 flex flex-wrap gap-2">
              <button
                phx-click="explorer_difficulty"
                phx-value-difficulty="easy"
                class={[
                  "btn btn-sm",
                  if(@explorer_difficulty == "easy", do: "btn-secondary", else: "btn-ghost")
                ]}
                id="explorer-difficulty-easy"
              >
                Easy
              </button>
              <button
                phx-click="explorer_difficulty"
                phx-value-difficulty="medium"
                class={[
                  "btn btn-sm",
                  if(@explorer_difficulty == "medium", do: "btn-secondary", else: "btn-ghost")
                ]}
                id="explorer-difficulty-medium"
              >
                Medium
              </button>
              <button
                phx-click="explorer_difficulty"
                phx-value-difficulty="hard"
                class={[
                  "btn btn-sm",
                  if(@explorer_difficulty == "hard", do: "btn-secondary", else: "btn-ghost")
                ]}
                id="explorer-difficulty-hard"
              >
                Hard
              </button>
              <button
                phx-click="explorer_difficulty"
                phx-value-difficulty=""
                class={[
                  "btn btn-sm",
                  if(@explorer_difficulty in [nil, ""], do: "btn-secondary", else: "btn-ghost")
                ]}
                id="explorer-difficulty-all"
              >
                Any
              </button>
            </div>
            
    <!-- Cuisine and Dietary Needs Row -->
            <div class="mt-3 flex flex-wrap items-center gap-2">
              <div class="relative">
                <input
                  id="explorer-cuisine-filter"
                  type="text"
                  name="cuisine"
                  value={@explorer_cuisine}
                  placeholder="Cuisine..."
                  phx-keyup="explorer_cuisine"
                  phx-debounce="300"
                  class="input input-sm w-32"
                />
              </div>

              <div class="dropdown">
                <label tabindex="0" class="btn btn-sm btn-ghost gap-1">
                  <.icon name="hero-funnel" class="w-4 h-4" /> Dietary
                  <%= if length(@explorer_dietary_needs) > 0 do %>
                    <span class="badge badge-sm badge-primary">
                      {length(@explorer_dietary_needs)}
                    </span>
                  <% end %>
                </label>
                <div
                  tabindex="0"
                  class="dropdown-content z-20 p-3 shadow-lg bg-base-100 rounded-box w-64 border border-base-200"
                >
                  <div class="text-xs font-semibold text-base-content/60 uppercase tracking-wide mb-2">
                    Dietary Needs
                  </div>
                  <div class="flex flex-wrap gap-2">
                    <%= for need <- dietary_needs_options() do %>
                      <button
                        phx-click="explorer_dietary_toggle"
                        phx-value-need={need}
                        class={[
                          "btn btn-xs",
                          if(need in @explorer_dietary_needs, do: "btn-accent", else: "btn-ghost")
                        ]}
                      >
                        {format_dietary_need(need)}
                      </button>
                    <% end %>
                  </div>
                </div>
              </div>
            </div>
          </div>

          <div class="p-4 space-y-8 overflow-y-auto flex-1">
            <%= if @explorer_favorite_recipes != [] do %>
              <section aria-labelledby="explorer-favorites-title">
                <div class="flex items-center justify-between gap-3 mb-3">
                  <div>
                    <h3
                      id="explorer-favorites-title"
                      class="text-base font-bold text-base-content"
                    >
                      Favorites
                    </h3>
                    <p class="text-sm text-base-content/60">Your go-to dishes, one tap away.</p>
                  </div>
                </div>

                <div class="grid gap-3 sm:grid-cols-2 xl:grid-cols-3" id="explorer-favorites">
                  <%= for recipe <- @explorer_favorite_recipes do %>
                    <.explorer_recipe_card recipe={recipe} id_prefix="favorite" />
                  <% end %>
                </div>
              </section>
            <% end %>

            <%= if @explorer_recent_recipes != [] do %>
              <section aria-labelledby="explorer-recent-title">
                <div class="flex items-center justify-between gap-3 mb-3">
                  <div>
                    <h3 id="explorer-recent-title" class="text-base font-bold text-base-content">
                      Recently planned
                    </h3>
                    <p class="text-sm text-base-content/60">Popular picks from this week.</p>
                  </div>
                </div>

                <div class="grid gap-3 sm:grid-cols-2 xl:grid-cols-3" id="explorer-recents">
                  <%= for recipe <- @explorer_recent_recipes do %>
                    <.explorer_recipe_card recipe={recipe} id_prefix="recent" />
                  <% end %>
                </div>
              </section>
            <% end %>

            <section aria-labelledby="explorer-all-title">
              <div class="flex items-center justify-between gap-3 mb-3">
                <div>
                  <h3 id="explorer-all-title" class="text-base font-bold text-base-content">
                    Explore
                  </h3>
                  <p class="text-sm text-base-content/60">
                    Fresh ideas to round out your week.
                  </p>
                </div>
              </div>

              <%= if @explorer_recipes == [] do %>
                <.empty_state_message
                  search={@explorer_search}
                  filter={@explorer_filter}
                  difficulty={@explorer_difficulty}
                  id_prefix="desktop"
                />
              <% else %>
                <div class="grid gap-3 sm:grid-cols-2 xl:grid-cols-3" id="explorer-feed">
                  <%= for recipe <- @explorer_recipes do %>
                    <.explorer_recipe_card recipe={recipe} id_prefix="feed" />
                  <% end %>
                </div>
              <% end %>
            </section>
          </div>
        </div>
      </div>
      
    <!-- Save Preset Modal -->
      <.save_preset_modal :if={@show_save_preset_modal} />
    </div>
    """
  end

  defp save_preset_modal(assigns) do
    ~H"""
    <div class="modal modal-open" id="save-preset-modal">
      <div class="modal-box max-w-sm">
        <h3 class="font-bold text-lg mb-4">Save Filter Preset</h3>
        <form phx-submit="explorer_save_preset">
          <div class="form-control">
            <label class="label">
              <span class="label-text">Preset name</span>
            </label>
            <input
              type="text"
              name="name"
              placeholder="e.g., Weeknight Quick Wins"
              class="input input-bordered w-full"
              required
              autofocus
            />
          </div>
          <div class="modal-action">
            <button type="button" phx-click="explorer_close_save_preset" class="btn btn-ghost">
              Cancel
            </button>
            <button type="submit" class="btn btn-primary">Save Preset</button>
          </div>
        </form>
      </div>
      <div class="modal-backdrop" phx-click="explorer_close_save_preset"></div>
    </div>
    """
  end

  defp has_active_filters?(assigns) do
    (assigns[:explorer_search] || "") != "" ||
      assigns[:explorer_filter] not in [nil, ""] ||
      assigns[:explorer_difficulty] not in [nil, ""] ||
      (assigns[:explorer_cuisine] || "") != "" ||
      length(assigns[:explorer_dietary_needs] || []) > 0
  end

  defp dietary_needs_options do
    [
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
  end

  defp format_dietary_need(need) do
    need
    |> to_string()
    |> String.replace("_", " ")
    |> String.split(" ")
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  # Find a preset by ID, checking both user presets and system presets
  defp find_preset(preset_id, user_presets, system_presets) do
    Enum.find(user_presets, &(&1.id == preset_id)) ||
      Enum.find(system_presets, &(&1.id == preset_id || &1[:id] == preset_id))
  end

  defp mobile_header(assigns) do
    ~H"""
    <div class="sticky top-0 z-10 bg-base-100 p-3 border-b border-base-300 shadow-sm">
      <div class="relative">
        <.icon
          name="hero-magnifying-glass"
          class="w-4 h-4 absolute left-3 top-1/2 -translate-y-1/2 text-base-content/40"
        />
        <input
          type="text"
          placeholder="Search recipes..."
          value={@explorer_search}
          class="input input-sm input-bordered w-full pl-9 rounded-full bg-base-200/50 focus:bg-base-100"
          phx-keyup="explorer_search"
          phx-debounce="300"
          name="query"
        />
      </div>
    </div>
    """
  end

  defp mobile_week_strip(assigns) do
    ~H"""
    <div class="bg-base-100 border-b border-base-300">
      <div class="flex items-center justify-between px-2 py-2">
        <button class="btn btn-ghost btn-xs btn-circle" phx-click="prev_week">
          <.icon name="hero-chevron-left" class="w-4 h-4" />
        </button>

        <div class="flex gap-1 flex-1 justify-center overflow-x-auto no-scrollbar">
          <%= for day <- @days do %>
            <% is_expanded = @expanded_day && Date.compare(day, @expanded_day) == :eq %>
            <button
              class={[
                "flex flex-col items-center p-1.5 rounded-xl min-w-[44px] transition-all",
                cond do
                  is_expanded ->
                    "bg-primary text-primary-content shadow-sm scale-105"

                  Date.compare(day, Date.utc_today()) == :eq ->
                    "bg-primary/10 text-primary border border-primary/20"

                  true ->
                    "hover:bg-base-200 text-base-content/70"
                end
              ]}
              phx-click={if is_expanded, do: "collapse_day", else: "expand_day"}
              phx-value-date={day}
            >
              <span class="text-[10px] font-medium uppercase tracking-wider">
                {Calendar.strftime(day, "%a")}
              </span>
              <span class="text-sm font-bold leading-tight">{day.day}</span>
              <div class="h-1.5 mt-0.5 flex gap-0.5">
                <% count = Enum.count(@week_meals[day] || []) %>
                <%= if count > 0 do %>
                  <span class={[
                    "w-1.5 h-1.5 rounded-full",
                    if(is_expanded, do: "bg-white", else: "bg-primary")
                  ]}>
                  </span>
                <% else %>
                  <span class={[
                    "w-1.5 h-1.5 rounded-full",
                    if(is_expanded, do: "bg-white/30", else: "bg-base-300")
                  ]}>
                  </span>
                <% end %>
              </div>
            </button>
          <% end %>
        </div>

        <button class="btn btn-ghost btn-xs btn-circle" phx-click="next_week">
          <.icon name="hero-chevron-right" class="w-4 h-4" />
        </button>
      </div>
    </div>
    """
  end

  defp mobile_expanded_day(assigns) do
    ~H"""
    <div class="bg-base-200/50 border-b border-base-300 animate-in slide-in-from-top-2 duration-200">
      <div class="p-3">
        <div class="flex items-center justify-between mb-3 px-1">
          <span class="font-bold text-sm text-base-content">
            {Calendar.strftime(@day, "%A, %B %d")}
          </span>
          <button class="btn btn-ghost btn-xs btn-circle" phx-click="collapse_day">
            <.icon name="hero-x-mark" class="w-4 h-4" />
          </button>
        </div>

        <div class="flex gap-3 overflow-x-auto pb-2 -mx-3 px-3 no-scrollbar snap-x snap-mandatory">
          <%= for meal_type <- [:breakfast, :lunch, :dinner, :snack] do %>
            <div class="snap-start shrink-0 w-[85vw] sm:w-[300px]">
              <%= case get_meal_plan(@day, meal_type, @week_meals) do %>
                <% nil -> %>
                  <.empty_slot_card
                    day={@day}
                    meal_type={meal_type}
                    available_recipes={@available_recipes}
                    favorites={@favorites}
                    recents={@recents}
                  />
                <% meal_plan -> %>
                  <div class="bg-base-100 rounded-xl p-3 border border-base-200 shadow-sm h-full flex gap-3 relative overflow-hidden group">
                    <div class="absolute top-0 left-0 w-1 h-full bg-primary"></div>

                    <%= if meal_plan.recipe.image_url do %>
                      <img
                        src={meal_plan.recipe.image_url}
                        class="w-16 h-16 rounded-lg object-cover bg-base-200"
                      />
                    <% else %>
                      <div class="w-16 h-16 rounded-lg bg-base-200 flex items-center justify-center shrink-0">
                        <.icon name="hero-cake" class="w-8 h-8 text-base-content/20" />
                      </div>
                    <% end %>

                    <div class="flex-1 min-w-0 flex flex-col justify-center">
                      <div class="text-[10px] uppercase tracking-wide text-base-content/50 font-semibold mb-0.5">
                        {meal_type}
                      </div>
                      <div class="font-bold text-base-content truncate">
                        {meal_plan.recipe.name}
                      </div>
                      <div class="flex gap-2 mt-1">
                        <button
                          phx-click="edit_meal"
                          phx-value-id={meal_plan.id}
                          class="text-xs text-primary hover:underline"
                        >
                          Edit
                        </button>
                        <button
                          phx-click="remove_meal"
                          phx-value-id={meal_plan.id}
                          class="text-xs text-error/70 hover:text-error hover:underline"
                        >
                          Remove
                        </button>
                      </div>
                    </div>
                  </div>
              <% end %>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp mobile_filter_bar(assigns) do
    # Count active filters for badge
    active_count = count_active_filters(assigns)

    assigns = assign(assigns, :active_count, active_count)

    ~H"""
    <div class="flex gap-2 px-3 py-2.5 overflow-x-auto border-b border-base-300 bg-base-100 no-scrollbar items-center">
      <%!-- Filter button that opens bottom sheet --%>
      <button
        phx-click="explorer_open_filter_sheet"
        class={[
          "btn btn-xs rounded-full px-3 flex-shrink-0 gap-1",
          if(@active_count > 0, do: "btn-primary", else: "btn-outline border-base-300")
        ]}
        id="mobile-filter-btn"
      >
        <.icon name="hero-adjustments-horizontal" class="w-3.5 h-3.5" /> Filters
        <span :if={@active_count > 0} class="badge badge-xs badge-primary-content">
          {@active_count}
        </span>
      </button>

      <%!-- Quick filter chips --%>
      <button
        phx-click="explorer_filter"
        phx-value-filter={if @explorer_filter == "quick", do: "", else: "quick"}
        class={[
          "btn btn-xs rounded-full px-3 flex-shrink-0",
          if(@explorer_filter == "quick",
            do: "btn-primary",
            else: "btn-ghost bg-base-200/50"
          )
        ]}
      >
        <.icon name="hero-clock" class="w-3 h-3" /> Quick
      </button>
      <button
        phx-click="explorer_filter"
        phx-value-filter={if @explorer_filter == "pantry", do: "", else: "pantry"}
        class={[
          "btn btn-xs rounded-full px-3 flex-shrink-0",
          if(@explorer_filter == "pantry",
            do: "btn-primary",
            else: "btn-ghost bg-base-200/50"
          )
        ]}
      >
        <.icon name="hero-archive-box" class="w-3 h-3" /> Pantry
      </button>

      <%!-- Active filter indicators --%>
      <span
        :if={@explorer_difficulty != ""}
        class="badge badge-sm badge-secondary gap-1 flex-shrink-0"
      >
        {String.capitalize(@explorer_difficulty)}
        <button
          phx-click="explorer_difficulty"
          phx-value-difficulty=""
          class="hover:text-secondary-content"
        >
          <.icon name="hero-x-mark" class="w-3 h-3" />
        </button>
      </span>
      <span
        :if={@explorer_cuisine != ""}
        class="badge badge-sm badge-info gap-1 flex-shrink-0"
      >
        {@explorer_cuisine}
        <button phx-click="explorer_cuisine" phx-value-value="" class="hover:text-info-content">
          <.icon name="hero-x-mark" class="w-3 h-3" />
        </button>
      </span>
      <%= for need <- Enum.take(@explorer_dietary_needs, 2) do %>
        <span class="badge badge-sm badge-accent gap-1 flex-shrink-0">
          {format_dietary_need(need)}
          <button
            phx-click="explorer_dietary_toggle"
            phx-value-need={need}
            class="hover:text-accent-content"
          >
            <.icon name="hero-x-mark" class="w-3 h-3" />
          </button>
        </span>
      <% end %>
      <span
        :if={length(@explorer_dietary_needs) > 2}
        class="badge badge-sm badge-ghost flex-shrink-0"
      >
        +{length(@explorer_dietary_needs) - 2}
      </span>

      <%!-- Clear all --%>
      <button
        :if={@active_count > 0}
        phx-click="explorer_clear_filters"
        class="btn btn-xs btn-ghost text-error flex-shrink-0 ml-auto"
      >
        Clear
      </button>
    </div>
    """
  end

  defp count_active_filters(assigns) do
    count = 0
    count = if assigns[:explorer_filter] not in [nil, ""], do: count + 1, else: count
    count = if assigns[:explorer_difficulty] not in [nil, ""], do: count + 1, else: count
    count = if (assigns[:explorer_cuisine] || "") != "", do: count + 1, else: count
    count = count + length(assigns[:explorer_dietary_needs] || [])
    count
  end

  defp mobile_filter_sheet(assigns) do
    ~H"""
    <div class="fixed inset-0 z-50 lg:hidden" id="mobile-filter-sheet">
      <%!-- Backdrop --%>
      <div
        class="absolute inset-0 bg-black/40 backdrop-blur-sm"
        phx-click="explorer_close_filter_sheet"
      >
      </div>

      <%!-- Sheet --%>
      <div class="absolute bottom-0 left-0 right-0 bg-base-100 rounded-t-3xl shadow-2xl max-h-[85vh] flex flex-col animate-in slide-in-from-bottom duration-300">
        <%!-- Handle --%>
        <div class="flex justify-center py-3">
          <div class="w-10 h-1 rounded-full bg-base-300"></div>
        </div>

        <%!-- Header --%>
        <div class="flex items-center justify-between px-5 pb-3 border-b border-base-200">
          <h3 class="text-lg font-bold">Filters & Sort</h3>
          <button phx-click="explorer_close_filter_sheet" class="btn btn-sm btn-ghost btn-circle">
            <.icon name="hero-x-mark" class="w-5 h-5" />
          </button>
        </div>

        <%!-- Content --%>
        <div class="flex-1 overflow-y-auto p-5 space-y-6">
          <%!-- Presets Section --%>
          <section>
            <h4 class="text-xs font-bold uppercase tracking-wider text-base-content/50 mb-3">
              Quick Presets
            </h4>
            <div class="flex flex-wrap gap-2">
              <%= for preset <- @system_presets do %>
                <button
                  phx-click="explorer_load_preset"
                  phx-value-preset_id={preset.id}
                  phx-value-system="true"
                  class={[
                    "btn btn-sm gap-1",
                    if(@selected_preset_id == preset.id, do: "btn-primary", else: "btn-outline")
                  ]}
                >
                  <.icon name="hero-sparkles" class="w-3.5 h-3.5" />
                  {preset.name}
                </button>
              <% end %>
              <%= for preset <- @filter_presets do %>
                <button
                  phx-click="explorer_load_preset"
                  phx-value-preset_id={preset.id}
                  class={[
                    "btn btn-sm",
                    if(@selected_preset_id == preset.id, do: "btn-primary", else: "btn-outline")
                  ]}
                >
                  {preset.name}
                </button>
              <% end %>
            </div>
          </section>

          <%!-- Time Filter --%>
          <section>
            <h4 class="text-xs font-bold uppercase tracking-wider text-base-content/50 mb-3">
              Cooking Time
            </h4>
            <div class="flex gap-2">
              <button
                phx-click="explorer_filter"
                phx-value-filter=""
                class={[
                  "btn btn-sm flex-1",
                  if(@explorer_filter in [nil, ""], do: "btn-primary", else: "btn-outline")
                ]}
              >
                Any
              </button>
              <button
                phx-click="explorer_filter"
                phx-value-filter="quick"
                class={[
                  "btn btn-sm flex-1",
                  if(@explorer_filter == "quick", do: "btn-primary", else: "btn-outline")
                ]}
              >
                Under 30 min
              </button>
              <button
                phx-click="explorer_filter"
                phx-value-filter="pantry"
                class={[
                  "btn btn-sm flex-1",
                  if(@explorer_filter == "pantry", do: "btn-primary", else: "btn-outline")
                ]}
              >
                Pantry-first
              </button>
            </div>
          </section>

          <%!-- Difficulty --%>
          <section>
            <h4 class="text-xs font-bold uppercase tracking-wider text-base-content/50 mb-3">
              Difficulty
            </h4>
            <div class="flex gap-2">
              <button
                phx-click="explorer_difficulty"
                phx-value-difficulty=""
                class={[
                  "btn btn-sm flex-1",
                  if(@explorer_difficulty in [nil, ""], do: "btn-secondary", else: "btn-outline")
                ]}
              >
                Any
              </button>
              <button
                phx-click="explorer_difficulty"
                phx-value-difficulty="easy"
                class={[
                  "btn btn-sm flex-1",
                  if(@explorer_difficulty == "easy", do: "btn-secondary", else: "btn-outline")
                ]}
              >
                Easy
              </button>
              <button
                phx-click="explorer_difficulty"
                phx-value-difficulty="medium"
                class={[
                  "btn btn-sm flex-1",
                  if(@explorer_difficulty == "medium", do: "btn-secondary", else: "btn-outline")
                ]}
              >
                Medium
              </button>
              <button
                phx-click="explorer_difficulty"
                phx-value-difficulty="hard"
                class={[
                  "btn btn-sm flex-1",
                  if(@explorer_difficulty == "hard", do: "btn-secondary", else: "btn-outline")
                ]}
              >
                Hard
              </button>
            </div>
          </section>

          <%!-- Cuisine --%>
          <section>
            <h4 class="text-xs font-bold uppercase tracking-wider text-base-content/50 mb-3">
              Cuisine
            </h4>
            <input
              type="text"
              name="cuisine"
              value={@explorer_cuisine}
              placeholder="e.g., Italian, Mexican, Thai..."
              phx-keyup="explorer_cuisine"
              phx-debounce="300"
              class="input input-bordered w-full"
            />
          </section>

          <%!-- Dietary Needs --%>
          <section>
            <h4 class="text-xs font-bold uppercase tracking-wider text-base-content/50 mb-3">
              Dietary Needs
            </h4>
            <div class="flex flex-wrap gap-2">
              <%= for need <- dietary_needs_options() do %>
                <button
                  phx-click="explorer_dietary_toggle"
                  phx-value-need={need}
                  class={[
                    "btn btn-sm",
                    if(need in @explorer_dietary_needs, do: "btn-accent", else: "btn-outline")
                  ]}
                >
                  {format_dietary_need(need)}
                </button>
              <% end %>
            </div>
          </section>

          <%!-- Sort --%>
          <section>
            <h4 class="text-xs font-bold uppercase tracking-wider text-base-content/50 mb-3">
              Sort By
            </h4>
            <div class="flex flex-wrap gap-2">
              <button
                phx-click="explorer_sort"
                phx-value-sort="name"
                class={[
                  "btn btn-sm",
                  if(@explorer_sort == "name", do: "btn-neutral", else: "btn-outline")
                ]}
              >
                Name
              </button>
              <button
                phx-click="explorer_sort"
                phx-value-sort="newest"
                class={[
                  "btn btn-sm",
                  if(@explorer_sort == "newest", do: "btn-neutral", else: "btn-outline")
                ]}
              >
                Newest
              </button>
              <button
                phx-click="explorer_sort"
                phx-value-sort="prep_time"
                class={[
                  "btn btn-sm",
                  if(@explorer_sort == "prep_time", do: "btn-neutral", else: "btn-outline")
                ]}
              >
                Prep Time
              </button>
              <button
                phx-click="explorer_sort"
                phx-value-sort="difficulty"
                class={[
                  "btn btn-sm",
                  if(@explorer_sort == "difficulty", do: "btn-neutral", else: "btn-outline")
                ]}
              >
                Difficulty
              </button>
            </div>
          </section>
        </div>

        <%!-- Footer actions --%>
        <div class="p-4 border-t border-base-200 flex gap-3">
          <button phx-click="explorer_clear_filters" class="btn btn-outline flex-1">
            Clear All
          </button>
          <button phx-click="explorer_close_filter_sheet" class="btn btn-primary flex-1">
            Apply
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp desktop_meal_slot(assigns) do
    ~H"""
    <%= case get_meal_plan(@day, @meal_type, @week_meals) do %>
      <% nil -> %>
        <.empty_slot_card
          day={@day}
          meal_type={@meal_type}
          available_recipes={@available_recipes}
          favorites={@favorites}
          recents={@recents}
          desktop={true}
          selected={@explorer_selected_slot == %{date: @day, meal_type: @meal_type}}
        />
      <% meal_plan -> %>
        <button
          phx-click="edit_meal"
          phx-value-id={meal_plan.id}
          class="group rounded-xl border border-base-200 bg-base-100 hover:border-primary/40 hover:shadow-sm transition-all px-3 py-3 text-left w-full"
          id={"explorer-slot-#{@day}-#{@meal_type}"}
          title="Edit meal"
        >
          <div class="flex items-center justify-between gap-2">
            <div class="text-sm font-semibold text-base-content capitalize flex items-center gap-2">
              <span class="text-base">
                {Terminology.meal_type_icon(@meal_type) |> Terminology.icon_to_emoji()}
              </span>
              <span>{@meal_type}</span>
            </div>
            <.icon
              name="hero-pencil-square"
              class="w-4 h-4 text-base-content/40 group-hover:text-primary"
            />
          </div>
          <div class="mt-1 text-xs font-semibold text-base-content truncate">
            {meal_plan.recipe.name}
          </div>
        </button>
    <% end %>
    """
  end

  defp empty_slot_card(assigns) do
    assigns = assign_new(assigns, :desktop, fn -> false end)
    assigns = assign_new(assigns, :selected, fn -> false end)

    ~H"""
    <div class={[
      "rounded-xl border border-dashed transition-all p-3 relative group",
      @desktop && "w-full",
      !@desktop && "h-full flex flex-col justify-center",
      @selected && "border-primary/50 bg-primary/5 shadow-sm",
      !@selected && "border-base-300 bg-base-100 hover:bg-primary/5 hover:border-primary/40"
    ]}>
      <div class="flex items-center justify-between mb-2">
        <div class="flex items-center gap-2">
          <span class="text-base">
            {Terminology.meal_type_icon(@meal_type) |> Terminology.icon_to_emoji()}
          </span>
          <span class="text-xs font-bold uppercase tracking-wide text-base-content/60">
            {@meal_type}
          </span>
        </div>
        <button
          phx-click="explorer_open_recipe_picker"
          phx-value-date={@day}
          phx-value-meal_type={@meal_type}
          class="btn btn-xs btn-circle btn-ghost hover:bg-primary hover:text-primary-content"
        >
          <.icon name="hero-plus" class="w-4 h-4" />
        </button>
      </div>
      
    <!-- Quick Picks -->
      <div class="grid grid-cols-3 gap-2 mt-1">
        <%= for recipe <- get_quick_picks(@available_recipes, @favorites, @recents) do %>
          <button
            phx-click="explorer_quick_add"
            phx-value-recipe_id={recipe.id}
            phx-value-date={@day}
            phx-value-meal_type={@meal_type}
            class="text-left group/chip"
            title={"Quick add #{recipe.name}"}
          >
            <div class="aspect-square rounded-lg bg-base-200 overflow-hidden relative mb-1">
              <%= if recipe.image_url do %>
                <img
                  src={recipe.image_url}
                  class="w-full h-full object-cover opacity-80 group-hover/chip:opacity-100 transition-opacity"
                />
              <% else %>
                <div class="w-full h-full flex items-center justify-center">
                  <span class="text-xs opacity-30">?</span>
                </div>
              <% end %>
              <div class="absolute inset-0 flex items-center justify-center opacity-0 group-hover/chip:opacity-100 bg-black/20 transition-opacity">
                <.icon name="hero-plus" class="w-4 h-4 text-white drop-shadow-md" />
              </div>
            </div>
            <div class="text-[10px] leading-tight truncate opacity-70 group-hover/chip:opacity-100 group-hover/chip:text-primary">
              {recipe.name}
            </div>
          </button>
        <% end %>
      </div>
    </div>
    """
  end

  defp recipe_tags(assigns) do
    cuisine = Map.get(assigns.recipe, :cuisine)
    dietary_needs = Map.get(assigns.recipe, :dietary_needs) || []

    # Only show if there's something to display
    has_tags = (cuisine && cuisine != "") || dietary_needs != []

    assigns =
      assigns
      |> assign(:cuisine, cuisine)
      |> assign(:dietary_needs, dietary_needs)
      |> assign(:has_tags, has_tags)

    ~H"""
    <div :if={@has_tags} class={["flex flex-wrap gap-1", @compact && "mt-1", !@compact && "mt-1.5"]}>
      <%!-- Cuisine tag --%>
      <span
        :if={@cuisine && @cuisine != ""}
        class={[
          "inline-flex items-center gap-0.5 rounded-full bg-info/10 text-info",
          @compact && "px-1.5 py-0.5 text-[9px]",
          !@compact && "px-2 py-0.5 text-[10px]"
        ]}
      >
        <.icon name="hero-globe-alt" class={if @compact, do: "w-2.5 h-2.5", else: "w-3 h-3"} />
        {@cuisine}
      </span>
      <%!-- Dietary needs tags (show first 2 on compact, first 3 on full) --%>
      <%= for need <- Enum.take(@dietary_needs, if(@compact, do: 2, else: 3)) do %>
        <span class={[
          "inline-flex items-center rounded-full",
          dietary_need_color(need),
          @compact && "px-1.5 py-0.5 text-[9px]",
          !@compact && "px-2 py-0.5 text-[10px]"
        ]}>
          {format_dietary_need(need)}
        </span>
      <% end %>
      <%!-- Show +N if there are more --%>
      <% remaining = length(@dietary_needs) - if(@compact, do: 2, else: 3) %>
      <span
        :if={remaining > 0}
        class={[
          "inline-flex items-center rounded-full bg-base-200 text-base-content/60",
          @compact && "px-1.5 py-0.5 text-[9px]",
          !@compact && "px-2 py-0.5 text-[10px]"
        ]}
      >
        +{remaining}
      </span>
    </div>
    """
  end

  defp dietary_need_color(need) do
    case need do
      :vegan -> "bg-success/10 text-success"
      :vegetarian -> "bg-success/10 text-success"
      :gluten_free -> "bg-warning/10 text-warning"
      :dairy_free -> "bg-warning/10 text-warning"
      :nut_free -> "bg-error/10 text-error"
      :keto -> "bg-accent/10 text-accent"
      :paleo -> "bg-accent/10 text-accent"
      _ -> "bg-secondary/10 text-secondary"
    end
  end

  defp empty_state_message(assigns) do
    assigns = assign_new(assigns, :id_prefix, fn -> "default" end)

    ~H"""
    <div class="py-12 text-center">
      <div class="mx-auto w-12 h-12 rounded-2xl bg-base-200 flex items-center justify-center">
        <.icon name="hero-magnifying-glass" class="w-6 h-6 text-base-content/30" />
      </div>
      <div class="mt-4 font-semibold text-base-content">No recipes found</div>
      <div class="mt-1 text-sm text-base-content/60">
        Try a different keyword or clear filters.
      </div>
      <button
        :if={
          @search != "" || @filter not in [nil, ""] ||
            @difficulty not in [nil, ""]
        }
        phx-click="explorer_clear_filters"
        class="btn btn-ghost btn-sm mt-4"
        id={"explorer-clear-filters-#{@id_prefix}"}
      >
        Clear filters
      </button>
    </div>
    """
  end

  defp explorer_recipe_card(assigns) do
    assigns = assign_new(assigns, :id_prefix, fn -> "card" end)
    assigns = assign_new(assigns, :compact, fn -> false end)

    ~H"""
    <div class="group rounded-2xl border border-base-200 bg-base-100 overflow-hidden hover:shadow-md hover:border-primary/30 transition-all flex flex-col">
      <div class="aspect-[4/3] bg-base-200/50 overflow-hidden relative">
        <%= if @recipe.image_url do %>
          <img
            src={@recipe.image_url}
            alt={@recipe.name}
            class="w-full h-full object-cover group-hover:scale-[1.02] transition-transform duration-300"
          />
        <% else %>
          <div class="w-full h-full flex items-center justify-center">
            <.icon name="hero-photo" class="w-10 h-10 text-base-content/20" />
          </div>
        <% end %>

        <%= if @compact do %>
          <button
            phx-click="explorer_open_slot_picker"
            phx-value-recipe_id={@recipe.id}
            class="absolute bottom-2 right-2 btn btn-circle btn-sm btn-primary shadow-lg opacity-0 group-hover:opacity-100 transition-opacity"
          >
            <.icon name="hero-plus" class="w-4 h-4" />
          </button>
        <% end %>
      </div>

      <div class="p-3 flex-1 flex flex-col">
        <div class="flex items-start justify-between gap-2 mb-1">
          <h4 class={[
            "font-bold text-base-content leading-tight line-clamp-2",
            @compact && "text-xs",
            !@compact && "text-sm"
          ]}>
            {@recipe.name}
          </h4>

          <%= unless @compact do %>
            <button
              phx-click="explorer_toggle_favorite"
              phx-value-recipe_id={@recipe.id}
              class={[
                "p-1 -mr-1 -mt-1 rounded-lg transition-colors",
                @recipe.is_favorite && "text-warning hover:bg-warning/10",
                !@recipe.is_favorite &&
                  "text-base-content/30 hover:text-warning hover:bg-warning/10"
              ]}
            >
              <.icon name="hero-star" class="w-4 h-4" />
            </button>
          <% end %>
        </div>

        <%!-- Cuisine & Dietary Tags --%>
        <.recipe_tags recipe={@recipe} compact={@compact} />

        <div class="mt-auto pt-2 flex gap-2 items-center">
          <%= if @compact do %>
            <div class="text-[10px] text-base-content/60">
              {@recipe.total_time_minutes}m
            </div>
          <% else %>
            <button
              phx-click="explorer_open_slot_picker"
              phx-value-recipe_id={@recipe.id}
              class="btn btn-primary btn-sm flex-1 text-xs"
              id={"explorer-#{@id_prefix}-add-#{@recipe.id}"}
            >
              <.icon name="hero-plus" class="w-3 h-3" /> Add
            </button>
            <.link
              navigate={~p"/recipes/#{@recipe.id}"}
              class="btn btn-ghost btn-sm px-2"
            >
              Details
            </.link>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  def handle_event("expand_day", %{"date" => date_str}, socket) do
    date = Date.from_iso8601!(date_str)
    {:noreply, assign(socket, :expanded_day, date)}
  end

  def handle_event("collapse_day", _, socket) do
    {:noreply, assign(socket, :expanded_day, nil)}
  end

  def handle_event("explorer_search", %{"value" => search_term}, socket) do
    socket =
      socket
      |> assign(:explorer_search, search_term)
      |> load_explorer_recipes()

    {:noreply, socket}
  end

  def handle_event("explorer_filter", %{"filter" => filter}, socket) do
    socket =
      socket
      |> assign(:explorer_filter, filter)
      |> load_explorer_recipes()

    {:noreply, socket}
  end

  def handle_event("explorer_difficulty", %{"difficulty" => difficulty}, socket) do
    socket =
      socket
      |> assign(:explorer_difficulty, difficulty)
      |> load_explorer_recipes()

    {:noreply, socket}
  end

  def handle_event("explorer_clear_filters", _params, socket) do
    socket =
      socket
      |> assign(:explorer_search, "")
      |> assign(:explorer_filter, "")
      |> assign(:explorer_difficulty, "")
      |> assign(:explorer_cuisine, "")
      |> assign(:explorer_dietary_needs, [])
      |> assign(:explorer_sort, "name")
      |> assign(:selected_preset_id, nil)
      |> assign(:show_mobile_filter_sheet, false)
      |> load_explorer_recipes()

    {:noreply, socket}
  end

  def handle_event("explorer_cuisine", %{"value" => cuisine}, socket) do
    socket =
      socket
      |> assign(:explorer_cuisine, cuisine)
      |> assign(:selected_preset_id, nil)
      |> load_explorer_recipes()

    {:noreply, socket}
  end

  def handle_event("explorer_dietary_toggle", %{"need" => need_str}, socket) do
    need = String.to_existing_atom(need_str)
    current = socket.assigns[:explorer_dietary_needs] || []

    updated =
      if need in current do
        List.delete(current, need)
      else
        [need | current]
      end

    socket =
      socket
      |> assign(:explorer_dietary_needs, updated)
      |> assign(:selected_preset_id, nil)
      |> load_explorer_recipes()

    {:noreply, socket}
  end

  # Mobile filter sheet events

  def handle_event("explorer_open_filter_sheet", _params, socket) do
    {:noreply, assign(socket, :show_mobile_filter_sheet, true)}
  end

  def handle_event("explorer_close_filter_sheet", _params, socket) do
    {:noreply, assign(socket, :show_mobile_filter_sheet, false)}
  end

  # Sort event

  def handle_event("explorer_sort", %{"sort" => sort}, socket) do
    socket =
      socket
      |> assign(:explorer_sort, sort)
      |> load_explorer_recipes()

    {:noreply, socket}
  end

  # Filter Preset Events

  def handle_event("explorer_load_preset", %{"preset_id" => preset_id} = params, socket) do
    # Check if it's a system preset or user preset
    is_system = params["system"] == "true" || String.starts_with?(preset_id, "system-")

    preset =
      if is_system do
        Enum.find(@system_presets, &(&1.id == preset_id))
      else
        Enum.find(socket.assigns.filter_presets, &(&1.id == preset_id))
      end

    if preset do
      criteria = preset.criteria || preset[:criteria] || %{}

      socket =
        socket
        |> assign(:explorer_search, Map.get(criteria, "search", ""))
        |> assign(:explorer_filter, Map.get(criteria, "filter", ""))
        |> assign(:explorer_difficulty, Map.get(criteria, "difficulty", ""))
        |> assign(:explorer_cuisine, Map.get(criteria, "cuisine", ""))
        |> assign(
          :explorer_dietary_needs,
          parse_dietary_needs(Map.get(criteria, "dietary_needs"))
        )
        |> assign(:selected_preset_id, preset_id)
        |> load_explorer_recipes()

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_event("explorer_open_save_preset", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_save_preset_modal, true)
     |> assign(:preset_name_input, "")}
  end

  def handle_event("explorer_close_save_preset", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_save_preset_modal, false)
     |> assign(:preset_name_input, "")}
  end

  def handle_event("explorer_save_preset", %{"name" => name}, socket) do
    criteria = %{
      "search" => socket.assigns.explorer_search,
      "filter" => socket.assigns.explorer_filter,
      "difficulty" => socket.assigns.explorer_difficulty,
      "cuisine" => socket.assigns[:explorer_cuisine] || "",
      "dietary_needs" => Enum.map(socket.assigns[:explorer_dietary_needs] || [], &to_string/1)
    }

    case GroceryPlanner.Recipes.create_filter_preset(
           socket.assigns.current_user.id,
           %{name: name, criteria: criteria},
           actor: socket.assigns.current_user
         ) do
      {:ok, preset} ->
        socket =
          socket
          |> assign(:filter_presets, [preset | socket.assigns.filter_presets])
          |> assign(:selected_preset_id, preset.id)
          |> assign(:show_save_preset_modal, false)
          |> assign(:preset_name_input, "")
          |> put_flash(:info, "Preset saved!")

        {:noreply, socket}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to save preset")}
    end
  end

  def handle_event("explorer_delete_preset", %{"preset_id" => preset_id}, socket) do
    preset = Enum.find(socket.assigns.filter_presets, &(&1.id == preset_id))

    if preset do
      case GroceryPlanner.Recipes.destroy_filter_preset(preset,
             actor: socket.assigns.current_user
           ) do
        :ok ->
          updated_presets = Enum.reject(socket.assigns.filter_presets, &(&1.id == preset_id))

          selected_id =
            if socket.assigns.selected_preset_id == preset_id,
              do: nil,
              else: socket.assigns.selected_preset_id

          {:noreply,
           socket
           |> assign(:filter_presets, updated_presets)
           |> assign(:selected_preset_id, selected_id)
           |> put_flash(:info, "Preset deleted")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to delete preset")}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("explorer_open_slot_picker", %{"recipe_id" => recipe_id} = params, socket) do
    recipe =
      Enum.find(socket.assigns.explorer_recipes, &(&1.id == recipe_id)) ||
        Enum.find(socket.assigns.explorer_recent_recipes, &(&1.id == recipe_id)) ||
        Enum.find(socket.assigns.explorer_favorite_recipes, &(&1.id == recipe_id)) ||
        Enum.find(socket.assigns.available_recipes, &(&1.id == recipe_id))

    if is_nil(recipe) do
      {:noreply, put_flash(socket, :error, "Recipe not available")}
    else
      selected_slot =
        cond do
          Map.has_key?(params, "date") and Map.has_key?(params, "meal_type") ->
            %{"date" => params["date"], "meal_type" => params["meal_type"]}

          is_map(socket.assigns.explorer_selected_slot) ->
            socket.assigns.explorer_selected_slot

          true ->
            %{"date" => Date.to_iso8601(Date.utc_today()), "meal_type" => "dinner"}
        end

      socket =
        socket
        |> assign(:show_explorer_slot_picker, true)
        |> assign(:explorer_picking_recipe, recipe)
        |> assign(:explorer_selected_slot, selected_slot)

      {:noreply, socket}
    end
  end

  def handle_event("explorer_close_slot_picker", _params, socket) do
    socket =
      socket
      |> assign(:show_explorer_slot_picker, false)
      |> assign(:explorer_picking_recipe, nil)
      |> assign(:explorer_selected_slot, nil)

    {:noreply, socket}
  end

  def handle_event("explorer_select_slot", %{"date" => date, "meal_type" => meal_type}, socket) do
    {:noreply,
     assign(socket, :explorer_selected_slot, %{"date" => date, "meal_type" => meal_type})}
  end

  def handle_event("explorer_confirm_add", _params, socket) do
    # Delegate to parent LiveView via message for consistency and UndoSystem access
    %{"date" => date_str, "meal_type" => meal_type_str} = socket.assigns.explorer_selected_slot
    recipe_id = socket.assigns.explorer_picking_recipe.id

    send(
      self(),
      {:add_meal_internal,
       %{
         recipe_id: recipe_id,
         date: Date.from_iso8601!(date_str),
         meal_type: String.to_existing_atom(meal_type_str)
       }}
    )

    socket =
      socket
      |> assign(:show_explorer_slot_picker, false)
      |> assign(:explorer_picking_recipe, nil)
      |> assign(:explorer_selected_slot, nil)

    {:noreply, socket}
  end

  def handle_event(
        "explorer_open_recipe_picker",
        %{"date" => date_str, "meal_type" => meal_type},
        socket
      ) do
    # This event opens the main recipe modal but pre-fills the slot info.
    # The parent LiveView manages the `show_add_meal_modal` state and `selected_date`.

    date = Date.from_iso8601!(date_str)
    meal_type_atom = String.to_existing_atom(meal_type)

    send(self(), {:open_add_meal_modal, %{date: date, meal_type: meal_type_atom}})

    # We also update local state to highlight the slot
    socket =
      socket
      |> assign(:explorer_selected_slot, %{date: date, meal_type: meal_type_atom})

    {:noreply, socket}
  end

  def handle_event("explorer_toggle_favorite", %{"recipe_id" => recipe_id}, socket) do
    # This also needs to call backend. Delegate?
    send(self(), {:toggle_favorite, recipe_id})
    {:noreply, socket}
  end

  def handle_event(
        "explorer_quick_add",
        %{"recipe_id" => recipe_id, "date" => date_str, "meal_type" => meal_type_str},
        socket
      ) do
    # Directly add to plan
    date = Date.from_iso8601!(date_str)
    meal_type = String.to_existing_atom(meal_type_str)

    send(
      self(),
      {:add_meal_internal,
       %{
         recipe_id: recipe_id,
         date: date,
         meal_type: meal_type
       }}
    )

    {:noreply, socket}
  end

  def handle_event("explorer_quick_add", %{"recipe_id" => recipe_id}, socket) do
    # Legacy handler if called without slot info (opens slot picker)
    handle_event("explorer_open_slot_picker", %{"recipe_id" => recipe_id}, socket)
  end

  defp parse_dietary_needs(nil), do: []

  defp parse_dietary_needs(list) when is_list(list) do
    Enum.map(list, fn
      s when is_binary(s) -> String.to_existing_atom(s)
      a when is_atom(a) -> a
    end)
  rescue
    _ -> []
  end

  defp parse_dietary_needs(_), do: []

  # Helper to load recipes with filters
  defp load_explorer_recipes(socket) do
    all_recipes = socket.assigns.available_recipes

    search_term = String.trim(socket.assigns.explorer_search || "")
    filter = socket.assigns.explorer_filter || ""
    difficulty = socket.assigns.explorer_difficulty || ""
    cuisine = String.trim(socket.assigns[:explorer_cuisine] || "")
    dietary_needs = socket.assigns[:explorer_dietary_needs] || []
    sort = socket.assigns[:explorer_sort] || "name"

    recipes =
      all_recipes
      |> maybe_filter_by_search(search_term)
      |> maybe_apply_explorer_filter(filter)
      |> maybe_filter_by_difficulty(difficulty)
      |> maybe_filter_by_cuisine(cuisine)
      |> maybe_filter_by_dietary_needs(dietary_needs)
      |> apply_sort(sort)

    {favorite_recipes, other_recipes} =
      Enum.split_with(recipes, & &1.is_favorite)

    # We might need recent recipe ids here. 
    # NOTE: meal_plans is assigned in DataLoader.load_week_meals which is called in parent.
    recent_ids = recent_recipe_ids_for_week(socket.assigns.meal_plans)

    recent_recipes =
      recipes
      |> Enum.filter(&(&1.id in recent_ids))
      |> Enum.sort_by(&Enum.find_index(recent_ids, fn id -> id == &1.id end))

    other_recipes =
      other_recipes
      |> Enum.reject(&(&1.id in recent_ids))
      |> Enum.take(24)

    socket
    |> assign(:explorer_favorite_recipes, Enum.take(favorite_recipes, 12))
    |> assign(:explorer_recent_recipes, Enum.take(recent_recipes, 12))
    |> assign(:explorer_recipes, other_recipes)
  end

  defp apply_sort(recipes, "name"), do: Enum.sort_by(recipes, & &1.name)

  defp apply_sort(recipes, "newest"),
    do: Enum.sort_by(recipes, & &1.inserted_at, {:desc, DateTime})

  defp apply_sort(recipes, "prep_time"),
    do: Enum.sort_by(recipes, &((&1.prep_time_minutes || 0) + (&1.cook_time_minutes || 0)))

  defp apply_sort(recipes, "difficulty") do
    difficulty_order = %{easy: 0, medium: 1, hard: 2}
    Enum.sort_by(recipes, &Map.get(difficulty_order, &1.difficulty, 1))
  end

  defp apply_sort(recipes, _), do: recipes

  defp get_quick_picks(recipes, favorites, recents) do
    # Heuristic: 
    # 1. 1x Favorite (random)
    # 2. 1x Recent (random from last 5)
    # 3. 1x Quick (under 20m) or Random from all

    pick1 = if favorites != [], do: Enum.random(favorites), else: nil
    pick2 = if recents != [], do: Enum.random(Enum.take(recents, 5)), else: nil

    available_for_pick3 =
      recipes
      |> Enum.reject(fn r -> (pick1 && r.id == pick1.id) || (pick2 && r.id == pick2.id) end)

    pick3 = if available_for_pick3 != [], do: Enum.random(available_for_pick3), else: nil

    [pick1, pick2, pick3] |> Enum.reject(&is_nil/1) |> Enum.take(3)
  end

  defp maybe_filter_by_search(recipes, ""), do: recipes

  defp maybe_filter_by_search(recipes, search_term) do
    Enum.filter(recipes, &GroceryPlanner.Recipes.name_matches?(&1, search_term))
  end

  defp maybe_apply_explorer_filter(recipes, ""), do: recipes

  defp maybe_apply_explorer_filter(recipes, "quick") do
    Enum.filter(recipes, fn recipe ->
      (recipe.prep_time_minutes || 0) + (recipe.cook_time_minutes || 0) <= 30
    end)
  end

  defp maybe_apply_explorer_filter(recipes, "pantry") do
    recipes
    |> Enum.sort_by(&length(&1.recipe_ingredients))
    |> Enum.take(24)
  end

  defp maybe_apply_explorer_filter(recipes, _), do: recipes

  defp maybe_filter_by_difficulty(recipes, ""), do: recipes

  defp maybe_filter_by_difficulty(recipes, difficulty)
       when difficulty in ["easy", "medium", "hard"] do
    difficulty_atom = String.to_existing_atom(difficulty)
    Enum.filter(recipes, fn recipe -> recipe.difficulty == difficulty_atom end)
  end

  defp maybe_filter_by_difficulty(recipes, _), do: recipes

  defp maybe_filter_by_cuisine(recipes, ""), do: recipes

  defp maybe_filter_by_cuisine(recipes, cuisine) do
    cuisine_lower = String.downcase(cuisine)

    Enum.filter(recipes, fn recipe ->
      recipe_cuisine = recipe.cuisine || ""
      String.contains?(String.downcase(recipe_cuisine), cuisine_lower)
    end)
  end

  defp maybe_filter_by_dietary_needs(recipes, []), do: recipes

  defp maybe_filter_by_dietary_needs(recipes, dietary_needs) when is_list(dietary_needs) do
    # Recipe must satisfy ALL selected dietary needs
    dietary_set = MapSet.new(dietary_needs)

    Enum.filter(recipes, fn recipe ->
      recipe_dietary = recipe.dietary_needs || []
      recipe_set = MapSet.new(recipe_dietary)
      MapSet.subset?(dietary_set, recipe_set)
    end)
  end

  defp maybe_filter_by_dietary_needs(recipes, _), do: recipes

  defp recent_recipe_ids_for_week(meal_plans) do
    meal_plans
    |> Enum.sort_by(& &1.scheduled_date, Date)
    |> Enum.map(& &1.recipe_id)
    |> Enum.uniq()
  end

  # Helper for safe map access
  defp get_meal_plan(date, meal_type, week_meals) do
    week_meals
    |> Map.get(date, %{})
    |> Map.get(meal_type)
  end
end
