defmodule GroceryPlanner.AI.CategorizerTest do
  use ExUnit.Case, async: false

  alias GroceryPlanner.AI.Categorizer
  alias GroceryPlanner.AiClient

  describe "confidence_level/1" do
    test "returns :high for confidence >= 0.80" do
      assert Categorizer.confidence_level(0.80) == :high
      assert Categorizer.confidence_level(0.95) == :high
      assert Categorizer.confidence_level(1.0) == :high
    end

    test "returns :medium for confidence >= 0.50 and < 0.80" do
      assert Categorizer.confidence_level(0.50) == :medium
      assert Categorizer.confidence_level(0.65) == :medium
      assert Categorizer.confidence_level(0.79) == :medium
    end

    test "returns :low for confidence < 0.50" do
      assert Categorizer.confidence_level(0.0) == :low
      assert Categorizer.confidence_level(0.30) == :low
      assert Categorizer.confidence_level(0.49) == :low
    end
  end

  describe "enabled?/0" do
    test "returns false when feature flag is disabled" do
      # Test config has ai_categorization: false
      refute Categorizer.enabled?()
    end

    test "returns true when feature flag is enabled" do
      original = Application.get_env(:grocery_planner, :features)

      Application.put_env(:grocery_planner, :features,
        ai_categorization: true,
        semantic_search: false
      )

      assert Categorizer.enabled?()

      Application.put_env(:grocery_planner, :features, original || [])
    end
  end

  describe "predict/2" do
    test "returns {:error, :disabled} when feature flag is off" do
      assert {:error, :disabled} = Categorizer.predict("Milk")
    end

    test "returns prediction when feature flag is on" do
      original = Application.get_env(:grocery_planner, :features)

      Application.put_env(:grocery_planner, :features,
        ai_categorization: true,
        semantic_search: false
      )

      Req.Test.stub(AiClient, fn conn ->
        Req.Test.json(conn, %{
          "request_id" => "req_test",
          "status" => "success",
          "payload" => %{
            "category" => "Dairy",
            "confidence" => 0.94,
            "confidence_level" => "high"
          }
        })
      end)

      assert {:ok, prediction} =
               Categorizer.predict("Milk",
                 candidate_labels: ["Dairy", "Produce"],
                 tenant_id: "test_tenant",
                 user_id: "test_user",
                 plug: {Req.Test, AiClient}
               )

      assert prediction.category == "Dairy"
      assert prediction.confidence == 0.94
      assert prediction.confidence_level == :high

      Application.put_env(:grocery_planner, :features, original || [])
    end

    test "returns error on AI service failure" do
      original = Application.get_env(:grocery_planner, :features)

      Application.put_env(:grocery_planner, :features,
        ai_categorization: true,
        semantic_search: false
      )

      Req.Test.stub(AiClient, fn conn ->
        Plug.Conn.send_resp(conn, 500, "Internal Server Error")
      end)

      assert {:error, _} =
               Categorizer.predict("Unknown",
                 tenant_id: "test_tenant",
                 user_id: "test_user",
                 plug: {Req.Test, AiClient}
               )

      Application.put_env(:grocery_planner, :features, original || [])
    end
  end

  describe "predict_batch/2" do
    test "returns {:error, :disabled} when feature flag is off" do
      assert {:error, :disabled} = Categorizer.predict_batch(["Milk", "Bread"])
    end

    test "returns {:error, :batch_too_large} for more than 50 items" do
      original = Application.get_env(:grocery_planner, :features)

      Application.put_env(:grocery_planner, :features,
        ai_categorization: true,
        semantic_search: false
      )

      items = for i <- 1..51, do: "Item #{i}"
      assert {:error, :batch_too_large} = Categorizer.predict_batch(items)

      Application.put_env(:grocery_planner, :features, original || [])
    end

    test "returns batch predictions when feature flag is on" do
      original = Application.get_env(:grocery_planner, :features)

      Application.put_env(:grocery_planner, :features,
        ai_categorization: true,
        semantic_search: false
      )

      Req.Test.stub(AiClient, fn conn ->
        Req.Test.json(conn, %{
          "request_id" => "req_batch_test",
          "status" => "success",
          "payload" => %{
            "predictions" => [
              %{
                "id" => "1",
                "name" => "whole milk",
                "predicted_category" => "Dairy",
                "confidence" => 0.94,
                "confidence_level" => "high"
              },
              %{
                "id" => "2",
                "name" => "bananas",
                "predicted_category" => "Produce",
                "confidence" => 0.91,
                "confidence_level" => "high"
              },
              %{
                "id" => "3",
                "name" => "dish soap",
                "predicted_category" => "Household",
                "confidence" => 0.55,
                "confidence_level" => "medium"
              }
            ]
          }
        })
      end)

      assert {:ok, results} =
               Categorizer.predict_batch(
                 ["whole milk", "bananas", "dish soap"],
                 tenant_id: "test_tenant",
                 user_id: "test_user",
                 plug: {Req.Test, AiClient}
               )

      assert length(results) == 3

      dairy = Enum.find(results, &(&1.name == "whole milk"))
      assert dairy.category == "Dairy"
      assert dairy.confidence == 0.94
      assert dairy.confidence_level == :high

      produce = Enum.find(results, &(&1.name == "bananas"))
      assert produce.category == "Produce"
      assert produce.confidence_level == :high

      household = Enum.find(results, &(&1.name == "dish soap"))
      assert household.category == "Household"
      assert household.confidence_level == :medium

      Application.put_env(:grocery_planner, :features, original || [])
    end

    test "returns error on AI service failure" do
      original = Application.get_env(:grocery_planner, :features)

      Application.put_env(:grocery_planner, :features,
        ai_categorization: true,
        semantic_search: false
      )

      Req.Test.stub(AiClient, fn conn ->
        Plug.Conn.send_resp(conn, 500, "Internal Server Error")
      end)

      assert {:error, _} =
               Categorizer.predict_batch(
                 ["milk", "bread"],
                 tenant_id: "test_tenant",
                 user_id: "test_user",
                 plug: {Req.Test, AiClient}
               )

      Application.put_env(:grocery_planner, :features, original || [])
    end
  end

  describe "predict/2 response normalization" do
    setup do
      original = Application.get_env(:grocery_planner, :features)

      Application.put_env(:grocery_planner, :features,
        ai_categorization: true,
        semantic_search: false
      )

      on_exit(fn -> Application.put_env(:grocery_planner, :features, original || []) end)
      :ok
    end

    defp stub_predict(payload) do
      Req.Test.stub(AiClient, fn conn ->
        Req.Test.json(conn, %{
          "request_id" => "req_test",
          "status" => "success",
          "payload" => payload
        })
      end)
    end

    test "coerces integer confidence to float and derives level" do
      stub_predict(%{"category" => "Dairy", "confidence" => 1})

      assert {:ok, prediction} = Categorizer.predict("Milk", plug: {Req.Test, AiClient})
      assert prediction.confidence === 1.0
      assert prediction.confidence_level == :high
    end

    test "defaults null/missing confidence to 0.0 with :low level" do
      stub_predict(%{"category" => "Dairy", "confidence" => nil})

      assert {:ok, prediction} = Categorizer.predict("Milk", plug: {Req.Test, AiClient})
      assert prediction.confidence === 0.0
      assert prediction.confidence_level == :low
    end

    test "derives confidence_level, ignoring the server confidence_level string" do
      stub_predict(%{
        "category" => "Dairy",
        "confidence" => 0.3,
        "confidence_level" => "totally_bogus"
      })

      assert {:ok, prediction} = Categorizer.predict("Milk", plug: {Req.Test, AiClient})
      assert prediction.confidence_level == :low
    end

    test "ignores unexpected extra keys in the payload without raising" do
      stub_predict(%{
        "category" => "Dairy",
        "confidence" => 0.9,
        "some_brand_new_field_the_server_added" => "surprise"
      })

      assert {:ok, prediction} = Categorizer.predict("Milk", plug: {Req.Test, AiClient})
      assert prediction.category == "Dairy"
    end

    test "returns {:error, :invalid_prediction} when category is missing" do
      stub_predict(%{"confidence" => 0.9})

      assert {:error, :invalid_prediction} =
               Categorizer.predict("Milk", plug: {Req.Test, AiClient})
    end
  end

  describe "predict_batch/2 response normalization" do
    setup do
      original = Application.get_env(:grocery_planner, :features)

      Application.put_env(:grocery_planner, :features,
        ai_categorization: true,
        semantic_search: false
      )

      on_exit(fn -> Application.put_env(:grocery_planner, :features, original || []) end)
      :ok
    end

    test "coerces integer confidence, derives level, and ignores extra keys" do
      Req.Test.stub(AiClient, fn conn ->
        Req.Test.json(conn, %{
          "request_id" => "req_batch_test",
          "status" => "success",
          "payload" => %{
            "predictions" => [
              %{
                "id" => "1",
                "name" => "whole milk",
                "predicted_category" => "Dairy",
                "confidence" => 1,
                "confidence_level" => "totally_bogus",
                "unexpected_field" => "surprise"
              }
            ]
          }
        })
      end)

      assert {:ok, [result]} =
               Categorizer.predict_batch(["whole milk"], plug: {Req.Test, AiClient})

      assert result.category == "Dairy"
      assert result.confidence === 1.0
      assert result.confidence_level == :high
    end

    test "returns {:error, :invalid_batch_response} when predictions is not a list" do
      Req.Test.stub(AiClient, fn conn ->
        Req.Test.json(conn, %{
          "request_id" => "req_batch_test",
          "status" => "success",
          "payload" => %{"predictions" => "not a list"}
        })
      end)

      assert {:error, :invalid_batch_response} =
               Categorizer.predict_batch(["whole milk"], plug: {Req.Test, AiClient})
    end
  end

  describe "default_candidate_labels/0" do
    test "returns a list of category strings" do
      labels = Categorizer.default_candidate_labels()
      assert is_list(labels)
      assert "Dairy" in labels
      assert "Produce" in labels
      assert length(labels) == 10
    end
  end
end
