defmodule GroceryPlannerWeb.UIComponents do
  @moduledoc """
  Reusable UI components for GroceryPlanner.

  This module provides standardized, theme-aware components that are used
  across the application for consistent UX and easier maintenance.

  ## Components

  **Phase 1:**
  - `empty_state/1` - Empty state placeholder
  - `stat_card/1` - KPI/statistic display card

  **Phase 2:**
  - `page_header/1` - Page title with description and optional actions
  - `section/1` - Section container with title
  - `list_item/1` - Horizontal list item with icon and actions

  Note: For modal dialogs, use the `modal/1` component from `CoreComponents`

  ## Usage

      import GroceryPlannerWeb.UIComponents

      <.empty_state icon="hero-cube" title="No items yet" />
      <.stat_card icon="hero-cube" color="primary" label="Total" value="42" />
  """
  use Phoenix.Component
  import GroceryPlannerWeb.CoreComponents

  @doc """
  Renders an empty state placeholder.

  Displays when a list or collection has no items, with optional action button.

  ## Attributes

  - `icon` - Required. Heroicon name (e.g., "hero-cube")
  - `title` - Required. Main message
  - `description` - Optional. Secondary message
  - `padding` - Optional. Padding class (default: "py-16")

  ## Slots

  - `action` - Optional slot for action button

  ## Examples

      <.empty_state
        icon="hero-book-open"
        title="No recipes yet"
        description="Click 'New Recipe' to add your first recipe"
      />

      <.empty_state icon="hero-shopping-cart" title="No shopping lists">
        <:action>
          <.button phx-click="new_list" class="btn-primary mt-4">
            Create List
          </.button>
        </:action>
      </.empty_state>
  """
  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :description, :string, default: nil
  attr :padding, :string, default: "py-16"

  slot :action

  def empty_state(assigns) do
    ~H"""
    <div class={"text-center #{@padding}"}>
      <.icon name={@icon} class="w-16 h-16 text-base-content/20 mx-auto mb-4" />
      <p class="text-base-content/50 font-medium">{@title}</p>
      <p :if={@description} class="text-base-content/30 text-sm mt-1">{@description}</p>
      <div :if={@action != []}>
        {render_slot(@action)}
      </div>
    </div>
    """
  end

  @doc """
  Renders a KPI/statistic card.

  Displays a key metric with icon, label, value, and optional description.
  Can be clickable (link) or static (div).

  ## Attributes

  - `icon` - Required. Heroicon name
  - `color` - Required. Semantic color (primary, success, warning, error, info, accent, secondary)
  - `label` - Required. Metric label
  - `value` - Required. Main value to display
  - `description` - Optional. Additional context
  - `link` - Optional. If provided, card becomes clickable link
  - `value_suffix` - Optional. Suffix for value (e.g., "items", "%")

  ## Examples

      <.stat_card
        icon="hero-cube"
        color="primary"
        label="Total Inventory"
        value="127"
        value_suffix="items"
        description="15 individual units"
      />

      <.stat_card
        icon="hero-fire"
        color="error"
        label="Expired"
        value="3"
        description="Remove immediately"
        link={~p"/inventory?expiring=expired"}
      />
  """
  attr :icon, :string, required: true
  attr :color, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :description, :string, default: nil
  attr :link, :string, default: nil
  attr :value_suffix, :string, default: nil

  def stat_card(%{link: nil} = assigns) do
    ~H"""
    <div class="bg-base-100 p-6 rounded-2xl shadow-sm border border-base-200">
      <div class="flex items-center gap-4">
        <div class={"w-12 h-12 bg-#{@color}/10 rounded-xl flex items-center justify-center text-#{@color}"}>
          <.icon name={@icon} class="w-6 h-6" />
        </div>
        <div>
          <p class="text-sm font-medium text-base-content/60">{@label}</p>
          <div class="flex items-baseline gap-2">
            <h3 class={"text-2xl font-bold text-#{stat_value_color(@color)}"}>{@value}</h3>
            <span :if={@value_suffix} class="text-sm text-base-content/60">{@value_suffix}</span>
          </div>
          <p :if={@description} class={"text-xs mt-1 #{stat_description_color(@color)}"}>
            {@description}
          </p>
        </div>
      </div>
    </div>
    """
  end

  def stat_card(assigns) do
    ~H"""
    <.link
      navigate={@link}
      class={"p-6 rounded-2xl border-2 hover:shadow-lg transition-all cursor-pointer bg-#{@color}/10 border-#{@color} hover:border-#{@color}"}
    >
      <h3 class={"text-sm font-medium mb-1 text-#{@color}"}>{@label}</h3>
      <div class="flex items-baseline gap-2">
        <p class={"text-3xl font-bold text-#{@color}"}>{@value}</p>
        <span :if={@value_suffix} class={"text-sm text-#{@color}/80"}>{@value_suffix}</span>
      </div>
      <p :if={@description} class={"text-sm mt-1 text-#{@color}/80"}>{@description}</p>
    </.link>
    """
  end

  # Helper to determine text color for stat card values
  defp stat_value_color("error"), do: "text-error"
  defp stat_value_color("warning"), do: "text-warning"
  defp stat_value_color("success"), do: "text-success"
  defp stat_value_color("info"), do: "text-info"
  defp stat_value_color("primary"), do: "text-base-content"
  defp stat_value_color("secondary"), do: "text-base-content"
  defp stat_value_color("accent"), do: "text-base-content"
  defp stat_value_color(_), do: "text-base-content"

  # Helper to determine description color for stat card
  defp stat_description_color("error"), do: "text-error"
  defp stat_description_color("warning"), do: "text-warning/80"
  defp stat_description_color("info"), do: "text-info/80"
  defp stat_description_color(_), do: "text-base-content/50"

  @doc """
  Renders a page header with title, description, and optional actions.

  Standardizes page header appearance across the application.

  ## Attributes

  - `title` - Required. Page title text
  - `description` - Optional. Descriptive text below title
  - `centered` - Optional. Center-align text (default: false)

  ## Slots

  - `actions` - Optional slot for action buttons in top-right

  ## Examples

      <.page_header title="Recipes" description="Browse and manage your recipe collection" />

      <.page_header title="Settings" description="Manage your account">
        <:actions>
          <.button phx-click="save" class="btn-primary">Save</.button>
        </:actions>
      </.page_header>

      <.page_header title="Welcome, John!" description="Dashboard" centered={true} />
  """
  attr :title, :string, required: true
  attr :description, :string, default: nil
  attr :show_description, :boolean, default: true
  attr :centered, :boolean, default: false

  slot :actions

  def page_header(assigns) do
    ~H"""
    <div class={[
      "mb-8",
      @centered && "text-center",
      @actions != [] && "flex items-start justify-between"
    ]}>
      <div class={@actions != [] && "flex-1"}>
        <h1 class="font-display text-5xl text-base-content">{@title}</h1>
        <p :if={@description && @show_description} class="mt-2 text-lg text-base-content/70">
          {@description}
        </p>
      </div>
      <div :if={@actions != []} class="flex gap-3 ml-4">
        {render_slot(@actions)}
      </div>
    </div>
    """
  end

  @doc """
  Renders a section container with title.

  Provides consistent styling for content sections with optional title.

  ## Attributes

  - `title` - Optional. Section title
  - `class` - Optional. Additional CSS classes

  ## Slots

  - `inner_block` - Required. Section content
  - `header_actions` - Optional. Actions in header next to title

  ## Examples

      <.section title="Spending Trends">
        <p>Chart content here</p>
      </.section>

      <.section title="Account Members">
        <:header_actions>
          <.button class="btn-secondary">Invite</.button>
        </:header_actions>
        <div>Members list...</div>
      </.section>

      <.section>
        <p>Content without title</p>
      </.section>
  """
  attr :title, :string, default: nil
  attr :class, :string, default: nil

  slot :inner_block, required: true
  slot :header_actions

  def section(assigns) do
    ~H"""
    <div class={"bg-base-100 p-6 rounded-2xl shadow-sm border border-base-200 #{@class}"}>
      <div :if={@title || @header_actions != []} class="flex items-center justify-between mb-6">
        <h3 :if={@title} class="font-display text-2xl text-base-content">{@title}</h3>
        <div :if={@header_actions != []} class="flex gap-2">
          {render_slot(@header_actions)}
        </div>
      </div>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  Renders a horizontal list item with icon, content, and actions.

  Provides consistent styling for list items across the application.

  ## Attributes

  - `icon` - Optional. Heroicon name
  - `icon_color` - Optional. Icon background color (default: "secondary")
  - `clickable` - Optional. Add hover effect (default: false)

  ## Slots

  - `icon_slot` - Optional alternative to icon attribute for custom icon content
  - `content` - Required. Main content area
  - `actions` - Optional. Action buttons on the right

  ## Examples

      <.list_item icon="hero-user" icon_color="primary">
        <:content>
          <p class="font-semibold">John Doe</p>
          <p class="text-sm text-base-content/70">john@example.com</p>
        </:content>
        <:actions>
          <.button class="btn-sm btn-error">Remove</.button>
        </:actions>
      </.list_item>

      <.list_item clickable={true}>
        <:icon_slot>
          <img src="/avatar.jpg" class="w-10 h-10 rounded-full" />
        </:icon_slot>
        <:content>
          <p>Custom content</p>
        </:content>
      </.list_item>
  """
  attr :icon, :string, default: nil
  attr :icon_color, :string, default: "secondary"
  attr :clickable, :boolean, default: false

  slot :icon_slot
  slot :content, required: true
  slot :actions

  def list_item(assigns) do
    ~H"""
    <div class={[
      "flex items-center justify-between p-4 bg-base-200/30 rounded-xl border border-base-200 transition",
      @clickable && "hover:border-#{@icon_color}/30 hover:bg-#{@icon_color}/5 cursor-pointer"
    ]}>
      <div class="flex items-center gap-4 flex-1">
        <div :if={@icon || @icon_slot != []}>
          <%= if @icon_slot != [] do %>
            {render_slot(@icon_slot)}
          <% else %>
            <div class={"w-10 h-10 bg-#{@icon_color}/10 rounded-lg flex items-center justify-center"}>
              <.icon name={@icon} class={"w-5 h-5 text-#{@icon_color}"} />
            </div>
          <% end %>
        </div>
        <div class="flex-1">
          {render_slot(@content)}
        </div>
      </div>
      <div :if={@actions != []} class="flex gap-2 ml-4">
        {render_slot(@actions)}
      </div>
    </div>
    """
  end

  @doc """
  Renders a navigation card for dashboard-style layouts.

  Displays a clickable card with icon, title, and description for main navigation.

  ## Attributes

  - `icon` - Required. Heroicon name or custom SVG path
  - `color` - Required. Semantic color (primary, secondary, accent, warning, info, error, success)
  - `title` - Required. Card title
  - `description` - Required. Card description text
  - `navigate` - Required. Phoenix route to navigate to

  ## Examples

      <.nav_card
        icon="hero-cube"
        color="primary"
        title="Inventory"
        description="Manage your grocery items and track what's in stock"
        navigate={~p"/inventory"}
      />

      <.nav_card
        icon="hero-calendar"
        color="accent"
        title="Meal Planning"
        description="Plan your meals for the week and stay organized"
        navigate={~p"/meal-planner"}
      />
  """
  attr :icon, :string, required: true
  attr :color, :string, required: true
  attr :title, :string, required: true
  attr :description, :string, required: true
  attr :navigate, :string, required: true

  def nav_card(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      class="group p-8 bg-base-100 rounded-box shadow-sm border border-base-200 hover:shadow-lg hover:border-{@color}/50 transition-all"
    >
      <div class={"w-12 h-12 bg-#{@color}/10 rounded-lg flex items-center justify-center mb-4 group-hover:bg-#{@color}/20 transition"}>
        <.icon name={@icon} class={"w-6 h-6 text-#{@color}"} />
      </div>
      <h3 class="text-xl font-semibold text-base-content mb-2">{@title}</h3>
      <p class="text-base-content/70">{@description}</p>
    </.link>
    """
  end

  @doc """
  Renders an item card for displaying recipes, inventory items, or similar entities.

  Displays a card with optional image, title, metadata, and action buttons.

  ## Attributes

  - `title` - Required. Card title
  - `image_url` - Optional. URL for card image
  - `description` - Optional. Card description text
  - `clickable` - Optional. Whether card is clickable (default: true)
  - `rest` - Additional attributes passed to the container (e.g., phx-click, phx-value-id)

  ## Slots

  - `image_placeholder` - Optional slot for custom image placeholder content
  - `title_actions` - Optional slot for actions next to title (e.g., favorite button)
  - `footer` - Optional slot for card footer content (metadata, badges, etc.)

  ## Examples

      <.item_card
        title={recipe.name}
        image_url={recipe.image_url}
        description={recipe.description}
        phx-click="view_recipe"
        phx-value-id={recipe.id}
      >
        <:title_actions>
          <button phx-click="toggle_favorite" class="text-warning">★</button>
        </:title_actions>
        <:footer>
          <span>30 min</span>
          <span>4 servings</span>
          <span class="badge badge-success">Easy</span>
        </:footer>
      </.item_card>
  """
  attr :title, :string, required: true
  attr :image_url, :string, default: nil
  attr :description, :string, default: nil
  attr :clickable, :boolean, default: true
  attr :rest, :global

  slot :image_placeholder
  slot :title_actions
  slot :footer

  def item_card(assigns) do
    ~H"""
    <div
      class={[
        "bg-base-100 rounded-box shadow-sm border border-base-200 overflow-hidden transition",
        @clickable && "hover:shadow-md cursor-pointer"
      ]}
      {@rest}
    >
      <%= if @image_url do %>
        <div class="h-48 bg-base-200">
          <img
            src={@image_url}
            alt={@title}
            class="w-full h-full object-cover"
            onerror="this.onerror=null; this.parentElement.innerHTML='<div class=\'h-48 bg-secondary/10 flex items-center justify-center\'><svg class=\'w-16 h-16 text-secondary/30\' fill=\'none\' stroke=\'currentColor\' viewBox=\'0 0 24 24\'><path stroke-linecap=\'round\' stroke-linejoin=\'round\' stroke-width=\'2\' d=\'M4 16l4.586-4.586a2 2 0 012.828 0L16 16m-2-2l1.586-1.586a2 2 0 012.828 0L20 14m-6-6h.01M6 20h12a2 2 0 002-2V6a2 2 0 00-2-2H6a2 2 0 00-2 2v12a2 2 0 002 2z\'></path></svg></div>';"
          />
        </div>
      <% else %>
        <%= if @image_placeholder != [] do %>
          {render_slot(@image_placeholder)}
        <% else %>
          <div class="h-48 bg-secondary/10 flex items-center justify-center">
            <.icon name="hero-photo" class="w-16 h-16 text-secondary/30" />
          </div>
        <% end %>
      <% end %>

      <div class="p-5">
        <div class="flex items-start justify-between mb-2">
          <h3 class="text-lg font-semibold text-base-content flex-1">{@title}</h3>
          <%= if @title_actions != [] do %>
            <div class="flex-shrink-0 ml-2">
              {render_slot(@title_actions)}
            </div>
          <% end %>
        </div>

        <p :if={@description} class="text-sm text-base-content/60 mb-3 line-clamp-2">
          {@description}
        </p>

        <%= if @footer != [] do %>
          <div class="flex items-center gap-4 text-sm text-base-content/50">
            {render_slot(@footer)}
          </div>
        <% end %>
      </div>
    </div>
    """
  end
end
