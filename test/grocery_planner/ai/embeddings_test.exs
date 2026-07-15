defmodule GroceryPlanner.AI.EmbeddingsTest do
  use GroceryPlanner.DataCase, async: true

  alias GroceryPlanner.AI.Embeddings

  # Import only create_recipe from MealPlanningTestHelpers to avoid conflicts
  import GroceryPlanner.MealPlanningTestHelpers, only: [create_recipe: 3]

  describe "enabled?/0" do
    test "returns false when semantic_search feature is disabled" do
      # Default test config has semantic_search: false
      refute Embeddings.enabled?()
    end

    test "returns true when semantic_search feature is enabled" do
      original = Application.get_env(:grocery_planner, :features)
      Application.put_env(:grocery_planner, :features, semantic_search: true)

      assert Embeddings.enabled?()

      # Restore
      Application.put_env(:grocery_planner, :features, original)
    end
  end

  describe "build_recipe_text/1" do
    test "builds text from recipe attributes" do
      recipe = %{
        name: "Pasta Carbonara",
        description: "Classic Italian pasta dish",
        instructions: "Cook pasta, add eggs and cheese",
        cuisine: "Italian",
        dietary_needs: ["gluten-free"],
        difficulty: :medium,
        prep_time_minutes: 10,
        cook_time_minutes: 20,
        recipe_ingredients: []
      }

      text = Embeddings.build_recipe_text(recipe)

      assert text =~ "Pasta Carbonara"
      assert text =~ "Classic Italian pasta dish"
      assert text =~ "Italian"
      assert text =~ "30 minutes"
      assert text =~ "medium"
      assert text =~ "gluten-free"
    end

    test "handles nil optional fields" do
      recipe = %{
        name: "Simple Dish",
        description: nil,
        instructions: nil,
        cuisine: nil,
        dietary_needs: nil,
        difficulty: nil,
        prep_time_minutes: nil,
        cook_time_minutes: nil,
        recipe_ingredients: []
      }

      text = Embeddings.build_recipe_text(recipe)

      assert text =~ "Simple Dish"
      refute text =~ "Cuisine"
      refute text =~ "Difficulty"
      refute text =~ "Time"
    end

    test "includes ingredient names when available" do
      recipe = %{
        name: "Salad",
        description: "Fresh salad",
        instructions: nil,
        cuisine: nil,
        dietary_needs: nil,
        difficulty: nil,
        prep_time_minutes: nil,
        cook_time_minutes: nil,
        recipe_ingredients: [
          %{grocery_item: %{name: "Lettuce"}},
          %{grocery_item: %{name: "Tomato"}}
        ]
      }

      text = Embeddings.build_recipe_text(recipe)

      assert text =~ "Lettuce"
      assert text =~ "Tomato"
      assert text =~ "Ingredients:"
    end

    test "handles empty dietary_needs list" do
      recipe = %{
        name: "Test Recipe",
        description: nil,
        instructions: nil,
        cuisine: nil,
        dietary_needs: [],
        difficulty: nil,
        prep_time_minutes: nil,
        cook_time_minutes: nil,
        recipe_ingredients: []
      }

      text = Embeddings.build_recipe_text(recipe)

      assert text =~ "Test Recipe"
      refute text =~ "Dietary:"
    end

    test "handles multiple dietary needs" do
      recipe = %{
        name: "Special Dish",
        description: nil,
        instructions: nil,
        cuisine: nil,
        dietary_needs: ["vegan", "gluten-free", "nut-free"],
        difficulty: nil,
        prep_time_minutes: nil,
        cook_time_minutes: nil,
        recipe_ingredients: []
      }

      text = Embeddings.build_recipe_text(recipe)

      assert text =~ "vegan"
      assert text =~ "gluten-free"
      assert text =~ "nut-free"
    end

    test "calculates total time from prep and cook" do
      recipe = %{
        name: "Quick Meal",
        description: nil,
        instructions: nil,
        cuisine: nil,
        dietary_needs: nil,
        difficulty: nil,
        prep_time_minutes: 5,
        cook_time_minutes: 10,
        recipe_ingredients: []
      }

      text = Embeddings.build_recipe_text(recipe)

      assert text =~ "15 minutes"
    end

    test "handles prep time only" do
      recipe = %{
        name: "No Cook",
        description: nil,
        instructions: nil,
        cuisine: nil,
        dietary_needs: nil,
        difficulty: nil,
        prep_time_minutes: 10,
        cook_time_minutes: nil,
        recipe_ingredients: []
      }

      text = Embeddings.build_recipe_text(recipe)

      assert text =~ "10 minutes"
    end
  end

  describe "generate/2" do
    test "calls AI service and returns embedding vector" do
      # Enable feature flag for this test
      original = Application.get_env(:grocery_planner, :features)

      Application.put_env(:grocery_planner, :features,
        semantic_search: true,
        ai_categorization: false
      )

      # Create a mock embedding vector (384 dims)
      mock_vector = List.duplicate(0.1, 384)

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        # Embed endpoints use flat schema: texts at top level
        assert decoded["texts"] != nil

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "version" => "1.0",
            "request_id" => decoded["request_id"],
            "model" => "all-MiniLM-L6-v2",
            "dimension" => 384,
            "embeddings" => [%{"id" => "1", "vector" => mock_vector}]
          })
        )
      end

      {:ok, vector} = Embeddings.generate("test text", plug: plug)
      assert length(vector) == 384
      assert Enum.all?(vector, &(&1 == 0.1))

      # Restore
      Application.put_env(:grocery_planner, :features, original)
    end

    test "handles map response format" do
      original = Application.get_env(:grocery_planner, :features)

      Application.put_env(:grocery_planner, :features,
        semantic_search: true,
        ai_categorization: false
      )

      mock_vector = List.duplicate(0.2, 384)

      plug = fn conn ->
        {:ok, _body, conn} = Plug.Conn.read_body(conn)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "embeddings" => [%{"id" => "1", "vector" => mock_vector}]
          })
        )
      end

      {:ok, vector} = Embeddings.generate("test", plug: plug)
      assert length(vector) == 384

      Application.put_env(:grocery_planner, :features, original)
    end

    test "returns {:error, :no_embedding} for an empty embeddings list without raising" do
      original = Application.get_env(:grocery_planner, :features)

      Application.put_env(:grocery_planner, :features,
        semantic_search: true,
        ai_categorization: false
      )

      plug = fn conn ->
        {:ok, _body, conn} = Plug.Conn.read_body(conn)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"embeddings" => []}))
      end

      assert {:error, :no_embedding} = Embeddings.generate("test", plug: plug)

      Application.put_env(:grocery_planner, :features, original)
    end

    test "handles error response" do
      original = Application.get_env(:grocery_planner, :features)

      Application.put_env(:grocery_planner, :features,
        semantic_search: true,
        ai_categorization: false
      )

      plug = fn conn ->
        {:ok, _body, conn} = Plug.Conn.read_body(conn)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(500, Jason.encode!(%{"error" => "Service unavailable"}))
      end

      assert {:error, _} = Embeddings.generate("test", plug: plug)

      Application.put_env(:grocery_planner, :features, original)
    end
  end

  describe "generate_batch/2" do
    test "generates embeddings for multiple texts" do
      original = Application.get_env(:grocery_planner, :features)

      Application.put_env(:grocery_planner, :features,
        semantic_search: true,
        ai_categorization: false
      )

      mock_vector1 = List.duplicate(0.1, 384)
      mock_vector2 = List.duplicate(0.2, 384)

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        # Embed endpoints use flat schema: texts at top level
        texts = decoded["texts"]
        assert length(texts) == 2

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "embeddings" => [
              %{"id" => "1", "vector" => mock_vector1},
              %{"id" => "2", "vector" => mock_vector2}
            ]
          })
        )
      end

      texts = [
        %{id: "1", text: "first text"},
        %{id: "2", text: "second text"}
      ]

      {:ok, embeddings} = Embeddings.generate_batch(texts, plug: plug)
      assert length(embeddings) == 2
      assert Enum.at(embeddings, 0).id == "1"
      assert Enum.at(embeddings, 1).id == "2"

      Application.put_env(:grocery_planner, :features, original)
    end
  end

  describe "search_recipes/2" do
    test "returns error when semantic search is disabled" do
      original = Application.get_env(:grocery_planner, :features, [])

      Application.put_env(
        :grocery_planner,
        :features,
        Keyword.put(original, :semantic_search, false)
      )

      assert {:error, :disabled} =
               Embeddings.search_recipes("test", account_id: Ecto.UUID.generate())

      Application.put_env(:grocery_planner, :features, original)
    end
  end

  describe "hybrid_search/2" do
    test "returns keyword results when semantic search is disabled" do
      account = create_account()
      user = create_user(account)

      # Create test recipes
      _recipe1 =
        create_recipe(account, user, %{
          name: "Chicken Pasta",
          description: "Delicious pasta with chicken"
        })

      _recipe2 =
        create_recipe(account, user, %{
          name: "Beef Tacos",
          description: "Mexican style tacos"
        })

      # Search should work with keyword matching only
      results = Embeddings.hybrid_search("pasta", account_id: account.id)
      assert is_list(results)
      assert length(results) >= 1

      # First result should be the pasta recipe
      assert Enum.any?(results, fn r -> r.name =~ "Pasta" end)
    end
  end
end
