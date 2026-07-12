defmodule GroceryPlanner.Onboarding.StarterData do
  @moduledoc """
  Defines the standard set of data for new accounts, now including dietary kits and recipe chains.
  """

  def locations do
    [
      %{name: "Fridge", temperature_zone: :cold},
      %{name: "Pantry", temperature_zone: :room_temp},
      %{name: "Freezer", temperature_zone: :frozen},
      %{name: "Cupboard", temperature_zone: :room_temp}
    ]
  end

  def categories do
    [
      %{name: "Produce", icon: "hero-cake"},
      %{name: "Dairy", icon: "hero-beaker"},
      %{name: "Meat", icon: "hero-fire"},
      %{name: "Pantry", icon: "hero-archive-box"},
      %{name: "Bakery", icon: "hero-cake"},
      %{name: "Frozen", icon: "hero-moon"},
      %{name: "Beverage", icon: "hero-cube"},
      %{name: "Household", icon: "hero-home"}
    ]
  end

  def kits do
    [:omnivore, :vegetarian, :vegan, :keto, :budget, :single_couple]
  end

  def grocery_items(kit \\ :omnivore) do
    all_items =
      recipes(kit)
      |> Enum.flat_map(fn r -> r.ingredients end)
      |> Enum.map(fn i -> i.item end)
      |> Enum.uniq()
      |> Enum.map(fn name ->
        %{
          name: name,
          category: infer_category(name),
          default_unit: "unit",
          is_waste_risk: is_waste_risk?(name)
        }
      end)

    # Add some basic staples if not present
    staples = [
      %{name: "Salt", category: "Pantry", default_unit: "g"},
      %{name: "Pepper", category: "Pantry", default_unit: "g"},
      %{name: "Olive Oil", category: "Pantry", default_unit: "ml"}
    ]

    (all_items ++ staples) |> Enum.uniq_by(& &1.name)
  end

  defp infer_category(name) do
    cond do
      name in ["Kale", "Leeks", "Onions", "Sweetcorn", "Spinach", "Cabbage"] -> "Produce"
      name in ["Whole Chicken", "Salmon", "Sausage", "Ground Beef"] -> "Meat"
      name in ["Arborio Rice", "Chicken Stock"] -> "Pantry"
      true -> "Pantry"
    end
  end

  defp is_waste_risk?(name) do
    name in ["Kale", "Cabbage", "Spinach", "Leeks", "Whole Chicken"]
  end

  def recipes(kit \\ :omnivore) do
    catalog = load_catalog()

    special_sequences =
      case kit do
        :single_couple -> green_bag_chain()
        k when k in [:omnivore, :budget] -> chicken_chain() ++ green_bag_chain()
        _ -> []
      end

    # Filter catalog based on kit if needed
    filtered_catalog =
      if kit == :single_couple do
        # For single/couple, maybe focus on smaller servings or specific categories
        Enum.filter(catalog, &(&1.servings <= 2))
      else
        filter_by_kit(catalog, kit)
      end

    special_sequences ++ filtered_catalog
  end

  defp load_catalog do
    :grocery_planner
    |> Application.app_dir("priv/recipe_catalog.json")
    |> File.read!()
    |> Jason.decode!(keys: :atoms)
  end

  defp filter_by_kit(catalog, :vegetarian) do
    Enum.filter(catalog, &(&1.category in ["Vegetarian", "Pasta", "Breakfast", "Dessert"]))
  end

  defp filter_by_kit(catalog, :vegan) do
    Enum.filter(catalog, &(&1.category in ["Vegan", "Vegetarian", "Pasta"]))
  end

  defp filter_by_kit(catalog, :keto) do
    Enum.filter(catalog, &(&1.category in ["Beef", "Chicken", "Seafood", "Pork", "Lamb"]))
  end

  defp filter_by_kit(catalog, _), do: catalog

  defp chicken_chain do
    [
      %{
        name: "Sunday Roast Chicken",
        description: "The anchor for your week. Roast now, reuse later.",
        instructions:
          "Season whole chicken with salt and pepper. Roast at 200C until internal temp is 75C. Rest and carve, keeping 500g of meat aside for follow-up meals.",
        difficulty: :medium,
        servings: 4,
        is_base_recipe: true,
        freezable: true,
        preservation_tip: "Carve meat and freeze in 250g portions for up to 3 months.",
        image_url: "https://www.themealdb.com/images/media/meals/qxutws1486978099.jpg",
        ingredients: [
          %{item: "Whole Chicken", quantity: 1, unit: "large"},
          %{item: "Salt", quantity: 10, unit: "g"},
          %{item: "Pepper", quantity: 5, unit: "g"}
        ]
      },
      %{
        name: "Chicken & Leek Risotto",
        description: "Uses leftover chicken meat from Sunday's roast.",
        instructions:
          "Sauté leeks. Add rice. Gradually add stock. Stir in leftover chicken at the end.",
        difficulty: :medium,
        servings: 2,
        is_follow_up: true,
        parent_recipe_name: "Sunday Roast Chicken",
        waste_reduction_tip: "Uses only 2 leeks. Save the rest of the bunch for the soup!",
        image_url: "https://www.themealdb.com/images/media/meals/qqwypw1504642429.jpg",
        ingredients: [
          %{item: "Roast Chicken Leftovers", quantity: 300, unit: "g", usage_type: :leftover},
          %{item: "Arborio Rice", quantity: 200, unit: "g"},
          %{item: "Leeks", quantity: 2, unit: "units"},
          %{item: "Chicken Stock", quantity: 700, unit: "ml"}
        ]
      },
      %{
        name: "Hearty Chicken & Corn Soup",
        description: "Maximum efficiency: uses the remaining chicken and any veggies.",
        instructions: "Simmer remaining chicken and corn in stock. Add noodles if desired.",
        difficulty: :easy,
        servings: 2,
        is_follow_up: true,
        parent_recipe_name: "Sunday Roast Chicken",
        image_url: "https://www.themealdb.com/images/media/meals/sutxtx1487965141.jpg",
        ingredients: [
          %{item: "Roast Chicken Leftovers", quantity: 200, unit: "g", usage_type: :leftover},
          %{item: "Sweetcorn", quantity: 1, unit: "can"},
          %{item: "Chicken Stock", quantity: 500, unit: "ml"}
        ]
      }
    ]
  end

  defp green_bag_chain do
    [
      %{
        name: "Pan-Seared Salmon with Crispy Kale",
        description: "A fresh, healthy start. Uses the first third of your kale bag.",
        instructions: "Sear salmon. Sauté kale with garlic until crispy. Serve together.",
        difficulty: :easy,
        servings: 2,
        is_base_recipe: true,
        waste_reduction_tip:
          "You've used 1/3 of the kale bag. Use the next 1/3 in tomorrow's pasta!",
        image_url: "https://www.themealdb.com/images/media/meals/1548772327.jpg",
        ingredients: [
          %{item: "Salmon", quantity: 2, unit: "fillets"},
          %{item: "Kale", quantity: 100, unit: "g"},
          %{item: "Garlic", quantity: 2, unit: "cloves"}
        ]
      },
      %{
        name: "Spicy Sausage & Kale Orecchiette",
        description: "Variety with a different protein, using the same fresh greens.",
        instructions: "Brown sausage. Boiled pasta. Toss with kale and red pepper flakes.",
        difficulty: :medium,
        servings: 2,
        is_follow_up: true,
        parent_recipe_name: "Pan-Seared Salmon with Crispy Kale",
        waste_reduction_tip: "Almost done with the kale! Use the final handful in a smoothie.",
        image_url: "https://www.themealdb.com/images/media/meals/ustsqw1468250014.jpg",
        ingredients: [
          %{item: "Sausage", quantity: 4, unit: "links"},
          %{item: "Kale", quantity: 100, unit: "g"},
          %{item: "Pasta", quantity: 200, unit: "g"}
        ]
      },
      %{
        name: "Green Recovery Smoothie",
        description: "Zero waste: use the rest of the kale and any wilting fruit.",
        instructions: "Blend kale, apple, ginger, and water until smooth.",
        difficulty: :easy,
        servings: 1,
        is_follow_up: true,
        parent_recipe_name: "Pan-Seared Salmon with Crispy Kale",
        image_url: "https://www.themealdb.com/images/media/meals/rsutuy1511179166.jpg",
        ingredients: [
          %{item: "Kale", quantity: 50, unit: "g"},
          %{item: "Apple", quantity: 1, unit: "unit"},
          %{item: "Ginger", quantity: 1, unit: "inch"}
        ]
      }
    ]
  end
end
