defmodule GroceryPlanner.Integration.AiServiceIntegrationTest do
  @moduledoc """
  Integration tests for categorization, embeddings, and live contract validation
  against the real Python AI service.

  These tests require the Python service to be running:

      AI_SERVICE_URL=http://localhost:8099 mix test.integration

  Or use: ./scripts/test-integration.sh
  """
  use GroceryPlanner.IntegrationCase, async: false

  alias GroceryPlanner.AiClient

  @moduletag :integration

  @context %{tenant_id: Ecto.UUID.generate(), user_id: Ecto.UUID.generate()}

  # ── Connectivity ────────────────────────────────────────────────

  describe "service connectivity" do
    test "health/ready endpoint returns ok with dependency checks" do
      assert service_healthy?(), "Python AI service not running at #{ai_service_url()}"

      {:ok, body} = AiClient.health_check()
      assert body["status"] in ["ok", "degraded"]
      assert is_map(body["checks"])
      # The sidecar is stateless now (Oban owns job state) — there is no database
      # check. Readiness reflects the model/OCR deps it actually uses (AI-006 Arc 4).
      refute Map.has_key?(body["checks"], "database")
      assert Map.has_key?(body["checks"], "tesseract")
    end
  end

  # ── Categorization ──────────────────────────────────────────────

  describe "categorization" do
    test "categorizes a grocery item with candidate labels" do
      {:ok, body} =
        AiClient.categorize_item(
          "Organic Bananas",
          ["Produce", "Dairy", "Bakery", "Meat", "Frozen"],
          @context
        )

      assert body["status"] == "success"
      payload = body["payload"]
      assert is_binary(payload["category"])
      assert is_number(payload["confidence"])
      assert payload["confidence"] >= 0.0 and payload["confidence"] <= 1.0
      assert payload["confidence_level"] in ["high", "medium", "low"]
    end

    test "categorization returns valid categories from candidate list" do
      candidates = ["Produce", "Dairy", "Bakery", "Meat"]

      {:ok, body} = AiClient.categorize_item("Whole Milk", candidates, @context)
      assert body["payload"]["category"] in candidates

      {:ok, body2} = AiClient.categorize_item("Fresh Broccoli", candidates, @context)
      assert body2["payload"]["category"] in candidates
    end

    test "batch categorization processes multiple items" do
      items = [
        %{id: "1", name: "Bananas"},
        %{id: "2", name: "Cheddar Cheese"},
        %{id: "3", name: "Sourdough Bread"}
      ]

      {:ok, body} =
        AiClient.categorize_batch(
          items,
          ["Produce", "Dairy", "Bakery", "Meat"],
          @context
        )

      assert body["status"] == "success"
      predictions = body["payload"]["predictions"]
      assert length(predictions) == 3

      for prediction <- predictions do
        assert prediction["id"] in ["1", "2", "3"]
        assert is_binary(prediction["predicted_category"])
        assert is_number(prediction["confidence"])
      end
    end
  end

  # ── Embeddings ──────────────────────────────────────────────────
  # Note: Embed endpoints use EmbedResponse (flat schema with version,
  # request_id, model, dimension, embeddings) NOT the BaseResponse
  # envelope (status, payload) used by categorization/extraction.

  describe "embeddings" do
    test "generates embedding vector for a single text" do
      {:ok, body} = AiClient.generate_embedding("Organic Bananas", @context)

      assert is_binary(body["model"])
      assert is_integer(body["dimension"])
      assert body["dimension"] > 0
      assert is_binary(body["request_id"])

      embeddings = body["embeddings"]
      assert length(embeddings) == 1
      embedding = hd(embeddings)
      assert embedding["id"] == "1"
      assert is_list(embedding["vector"])
      assert length(embedding["vector"]) == body["dimension"]
    end

    test "generates embeddings for multiple texts" do
      texts = [
        %{id: "a", text: "Fresh Bananas"},
        %{id: "b", text: "Whole Milk"},
        %{id: "c", text: "Rye Bread"}
      ]

      {:ok, body} = AiClient.generate_embeddings(texts, @context)

      embeddings = body["embeddings"]
      assert length(embeddings) == 3

      ids = Enum.map(embeddings, & &1["id"])
      assert "a" in ids
      assert "b" in ids
      assert "c" in ids
    end

    test "embedding vectors have consistent dimensions across calls" do
      {:ok, body1} = AiClient.generate_embedding("Bananas", @context)
      {:ok, body2} = AiClient.generate_embedding("Milk", @context)

      dim1 = body1["dimension"]
      dim2 = body2["dimension"]
      assert dim1 == dim2, "Embedding dimensions should be consistent: #{dim1} vs #{dim2}"

      vec1 = hd(body1["embeddings"])["vector"]
      vec2 = hd(body2["embeddings"])["vector"]
      assert length(vec1) == dim1
      assert length(vec2) == dim2
    end

    test "batch embeddings with custom batch_size" do
      texts = Enum.map(1..5, &%{id: "#{&1}", text: "Item #{&1}"})

      {:ok, body} = AiClient.generate_embeddings_batch(texts, @context, batch_size: 2)

      assert is_binary(body["model"])
      assert length(body["embeddings"]) == 5
    end
  end

  # ── Base Response Envelope ──────────────────────────────────────

  describe "response envelope contract" do
    test "embed response uses EmbedResponse schema (not BaseResponse)" do
      {:ok, body} = AiClient.generate_embedding("test", @context)

      # Embed endpoints return EmbedResponse, not BaseResponse
      assert is_binary(body["request_id"])
      assert is_binary(body["model"])
      assert is_integer(body["dimension"])
      assert is_list(body["embeddings"])
      # Verify it does NOT have BaseResponse fields
      refute Map.has_key?(body, "status")
      refute Map.has_key?(body, "payload")
    end
  end

  # ── Error Handling ──────────────────────────────────────────────

  describe "error handling" do
    test "categorization with empty candidate labels" do
      result = AiClient.categorize_item("Milk", [], @context)

      case result do
        {:error, _} -> :ok
        {:ok, body} -> assert is_map(body)
      end
    end

    test "embedding with empty text list" do
      result = AiClient.generate_embeddings([], @context)

      case result do
        {:ok, body} ->
          assert is_list(body["embeddings"])

        {:error, _} ->
          :ok
      end
    end
  end
end
