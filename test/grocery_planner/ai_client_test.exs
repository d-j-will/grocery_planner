defmodule GroceryPlanner.AiClientTest do
  @moduledoc """
  Behavioral tests for the AiClient module.

  Tests all core AI service client functions using Req.Test stubs.
  Covers request construction, response handling, error paths, and
  cross-cutting concerns like request_id generation and context propagation.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias GroceryPlanner.AiClient

  @context %{tenant_id: "test-tenant", user_id: "test-user"}

  # ── Categorization ──────────────────────────────────────────────

  describe "categorize_item/4" do
    test "returns {:ok, body} with predicted category on success" do
      Req.Test.stub(AiClient, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["feature"] == "categorization"
        assert decoded["payload"]["item_name"] == "Organic Bananas"
        assert decoded["payload"]["candidate_labels"] == ["Produce", "Dairy", "Bakery"]
        assert decoded["tenant_id"] == "test-tenant"
        assert decoded["user_id"] == "test-user"
        assert String.starts_with?(decoded["request_id"], "req_")

        Req.Test.json(conn, %{
          "request_id" => decoded["request_id"],
          "status" => "success",
          "payload" => %{
            "category" => "Produce",
            "confidence" => 0.95,
            "confidence_level" => "high",
            "all_scores" => %{"Produce" => 0.95, "Dairy" => 0.03, "Bakery" => 0.02},
            "processing_time_ms" => 42.5
          }
        })
      end)

      assert {:ok, body} =
               AiClient.categorize_item(
                 "Organic Bananas",
                 ["Produce", "Dairy", "Bakery"],
                 @context
               )

      assert body["status"] == "success"
      assert body["payload"]["category"] == "Produce"
      assert body["payload"]["confidence"] == 0.95
    end

    test "returns {:error, body} on 500 server error" do
      Req.Test.stub(AiClient, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(500, Jason.encode!(%{"error" => "model_not_loaded"}))
      end)

      assert {:error, _} = AiClient.categorize_item("Milk", ["Dairy"], @context)
    end

    test "returns {:error, _} on connection failure" do
      Req.Test.stub(AiClient, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert {:error, _} = AiClient.categorize_item("Milk", ["Dairy"], @context)
    end
  end

  describe "categorize_batch/4" do
    test "sends batch of items and receives predictions" do
      items = [
        %{id: "1", name: "Bananas"},
        %{id: "2", name: "Whole Milk"},
        %{id: "3", name: "Sourdough Bread"}
      ]

      Req.Test.stub(AiClient, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["feature"] == "categorization_batch"
        assert length(decoded["payload"]["items"]) == 3
        assert decoded["payload"]["candidate_labels"] == ["Produce", "Dairy", "Bakery"]

        Req.Test.json(conn, %{
          "request_id" => decoded["request_id"],
          "status" => "success",
          "payload" => %{
            "predictions" => [
              %{
                "id" => "1",
                "name" => "Bananas",
                "predicted_category" => "Produce",
                "confidence" => 0.92,
                "confidence_level" => "high"
              },
              %{
                "id" => "2",
                "name" => "Whole Milk",
                "predicted_category" => "Dairy",
                "confidence" => 0.98,
                "confidence_level" => "high"
              },
              %{
                "id" => "3",
                "name" => "Sourdough Bread",
                "predicted_category" => "Bakery",
                "confidence" => 0.88,
                "confidence_level" => "high"
              }
            ],
            "processing_time_ms" => 120.3
          }
        })
      end)

      assert {:ok, body} =
               AiClient.categorize_batch(items, ["Produce", "Dairy", "Bakery"], @context)

      predictions = body["payload"]["predictions"]
      assert length(predictions) == 3
      assert Enum.at(predictions, 0)["predicted_category"] == "Produce"
      assert Enum.at(predictions, 1)["predicted_category"] == "Dairy"
    end

    test "returns error when batch exceeds server limits" do
      Req.Test.stub(AiClient, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          400,
          Jason.encode!(%{
            "error" => "batch_too_large",
            "detail" => "Maximum 50 items per batch"
          })
        )
      end)

      items = Enum.map(1..51, &%{id: "#{&1}", name: "Item #{&1}"})
      # 400 is classified as bad input (§4a); detail carries the decoded body.
      assert {:error, {:bad_input, detail}} =
               AiClient.categorize_batch(items, ["Produce"], @context)

      assert detail["error"] == "batch_too_large"
    end
  end

  # ── Receipt Extraction ──────────────────────────────────────────

  describe "extract_receipt/3" do
    test "sends base64 image and receives extracted line items" do
      fake_image = Base.encode64("fake_png_data")

      Req.Test.stub(AiClient, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["feature"] == "extraction"
        assert decoded["payload"]["image_base64"] == fake_image

        # Flat wire shape (schemas.py ExtractionResponsePayload) — the only
        # receipt shape the sidecar emits.
        Req.Test.json(conn, %{
          "request_id" => decoded["request_id"],
          "status" => "success",
          "payload" => %{
            "merchant" => "Trader Joe's",
            "date" => "2026-01-15",
            "total" => 47.82,
            "currency" => "USD",
            "raw_ocr_text" => "TRADER JOE'S\nBANANAS ORG\nMILK WHL GAL",
            "overall_confidence" => 0.87,
            "model_version" => "tesseract-5.3.0",
            "processing_time_ms" => 812.0,
            "items" => [
              %{
                "name" => "Organic Bananas",
                "quantity" => 1,
                "unit" => "bunch",
                "price" => 2.99,
                "confidence" => 0.90
              },
              %{
                "name" => "Whole Milk Gallon",
                "quantity" => 1,
                "unit" => "each",
                "price" => 4.49,
                "confidence" => 0.85
              }
            ]
          }
        })
      end)

      assert {:ok, body} = AiClient.extract_receipt(fake_image, @context)
      payload = body["payload"]
      assert payload["merchant"] == "Trader Joe's"
      assert payload["currency"] == "USD"
      assert length(payload["items"]) == 2
      assert payload["overall_confidence"] > 0.0
    end

    test "handles OCR failure gracefully" do
      Req.Test.stub(AiClient, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          500,
          Jason.encode!(%{
            "status" => "error",
            "error" => "ocr_failed",
            "payload" => nil
          })
        )
      end)

      # 500 is a transient server error (§4a); detail carries the decoded body.
      assert {:error, {:transient, detail}} = AiClient.extract_receipt("bad_data", @context)
      assert detail["error"] == "ocr_failed"
    end
  end

  # ── Embeddings ──────────────────────────────────────────────────

  describe "generate_embedding/3" do
    test "wraps single text in batch format and returns embedding" do
      Req.Test.stub(AiClient, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        # Embed endpoints use flat schema, not BaseRequest envelope
        assert decoded["version"] == "1.0"
        assert String.starts_with?(decoded["request_id"], "req_")
        texts = decoded["texts"]
        assert length(texts) == 1
        assert hd(texts)["id"] == "1"
        assert hd(texts)["text"] == "Organic Bananas"
        refute Map.has_key?(decoded, "feature")
        refute Map.has_key?(decoded, "payload")

        Req.Test.json(conn, %{
          "request_id" => decoded["request_id"],
          "status" => "success",
          "payload" => %{
            "model" => "all-MiniLM-L6-v2",
            "dimension" => 384,
            "embeddings" => [
              %{"id" => "1", "vector" => List.duplicate(0.1, 384)}
            ]
          }
        })
      end)

      assert {:ok, body} = AiClient.generate_embedding("Organic Bananas", @context)
      embeddings = body["payload"]["embeddings"]
      assert length(embeddings) == 1
      assert length(hd(embeddings)["vector"]) == 384
    end
  end

  describe "generate_embeddings/3" do
    test "sends multiple texts and receives vectors" do
      texts = [
        %{id: "a", text: "Bananas"},
        %{id: "b", text: "Milk"},
        %{id: "c", text: "Bread"}
      ]

      Req.Test.stub(AiClient, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        # Flat schema: texts at top level
        assert length(decoded["texts"]) == 3
        assert decoded["version"] == "1.0"

        Req.Test.json(conn, %{
          "request_id" => decoded["request_id"],
          "status" => "success",
          "payload" => %{
            "model" => "all-MiniLM-L6-v2",
            "dimension" => 384,
            "embeddings" =>
              Enum.map(texts, fn t ->
                %{"id" => t.id, "vector" => List.duplicate(0.01, 384)}
              end)
          }
        })
      end)

      assert {:ok, body} = AiClient.generate_embeddings(texts, @context)
      assert length(body["payload"]["embeddings"]) == 3
    end

    test "returns error on embedding service failure" do
      Req.Test.stub(AiClient, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(503, Jason.encode!(%{"error" => "model_loading"}))
      end)

      assert {:error, _} = AiClient.generate_embeddings([%{id: "1", text: "test"}], @context)
    end
  end

  describe "generate_embeddings_batch/3" do
    test "sends batch with configurable batch_size" do
      Req.Test.stub(AiClient, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        # Flat schema: batch_size at top level, not in payload
        assert decoded["version"] == "1.0"
        assert decoded["batch_size"] == 16
        refute Map.has_key?(decoded, "feature")

        Req.Test.json(conn, %{
          "request_id" => decoded["request_id"],
          "status" => "success",
          "payload" => %{
            "model" => "all-MiniLM-L6-v2",
            "dimension" => 384,
            "embeddings" => [
              %{"id" => "1", "vector" => List.duplicate(0.0, 384)}
            ]
          }
        })
      end)

      texts = [%{id: "1", text: "test"}]
      assert {:ok, _} = AiClient.generate_embeddings_batch(texts, @context, batch_size: 16)
    end

    test "defaults batch_size to 32" do
      Req.Test.stub(AiClient, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        # Flat schema: batch_size at top level
        assert decoded["batch_size"] == 32
        assert decoded["version"] == "1.0"

        Req.Test.json(conn, %{
          "status" => "success",
          "payload" => %{"model" => "test", "dimension" => 384, "embeddings" => []}
        })
      end)

      assert {:ok, _} = AiClient.generate_embeddings_batch([], @context)
    end
  end

  # ── Cross-Cutting Behavioral Tests ──────────────────────────────

  describe "request construction" do
    test "POST functions include request_id with req_ prefix" do
      Req.Test.stub(AiClient, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert String.starts_with?(decoded["request_id"], "req_")

        Req.Test.json(conn, %{"status" => "success", "payload" => %{}})
      end)

      assert {:ok, _} = AiClient.categorize_item("test", ["A"], @context)
    end

    test "POST functions include tenant_id and user_id from context" do
      Req.Test.stub(AiClient, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["tenant_id"] == "custom-tenant"
        assert decoded["user_id"] == "custom-user"

        Req.Test.json(conn, %{"status" => "success", "payload" => %{}})
      end)

      ctx = %{tenant_id: "custom-tenant", user_id: "custom-user"}
      assert {:ok, _} = AiClient.categorize_item("test", ["A"], ctx)
    end

    test "each function sends to the correct endpoint" do
      endpoints_called = :ets.new(:endpoints, [:set, :public])

      Req.Test.stub(AiClient, fn conn ->
        :ets.insert(endpoints_called, {conn.request_path, conn.method})
        Req.Test.json(conn, %{"status" => "success", "payload" => %{}})
      end)

      AiClient.categorize_item("x", ["A"], @context)

      assert :ets.lookup(endpoints_called, "/api/v1/categorize") ==
               [{"/api/v1/categorize", "POST"}]

      AiClient.categorize_batch([], ["A"], @context)

      assert :ets.lookup(endpoints_called, "/api/v1/categorize-batch") ==
               [{"/api/v1/categorize-batch", "POST"}]

      AiClient.extract_receipt("x", @context)

      assert :ets.lookup(endpoints_called, "/api/v1/extract-receipt") ==
               [{"/api/v1/extract-receipt", "POST"}]

      AiClient.generate_embeddings([], @context)
      assert :ets.lookup(endpoints_called, "/api/v1/embed") == [{"/api/v1/embed", "POST"}]

      AiClient.generate_embeddings_batch([], @context)

      assert :ets.lookup(endpoints_called, "/api/v1/embed/batch") ==
               [{"/api/v1/embed/batch", "POST"}]

      :ets.delete(endpoints_called)
    end
  end

  describe "error handling consistency" do
    test "all functions return {:error, _} on connection timeout" do
      Req.Test.stub(AiClient, fn conn ->
        Req.Test.transport_error(conn, :timeout)
      end)

      assert {:error, _} = AiClient.categorize_item("x", ["A"], @context)
      assert {:error, _} = AiClient.categorize_batch([], ["A"], @context)
      assert {:error, _} = AiClient.extract_receipt("x", @context)
      assert {:error, _} = AiClient.generate_embeddings([], @context)
      assert {:error, _} = AiClient.generate_embeddings_batch([], @context)
      assert {:error, _} = AiClient.health_check()
    end

    test "functions return {:error, _} on 4xx/5xx responses" do
      for status <- [400, 403, 404, 422, 429, 500, 502, 503] do
        Req.Test.stub(AiClient, fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(status, Jason.encode!(%{"error" => "status_#{status}"}))
        end)

        assert {:error, _} = AiClient.categorize_item("x", ["A"], @context),
               "Expected {:error, _} for status #{status}"
      end
    end
  end

  # ── Response Classification (AI-006 §4a) ────────────────────────
  #
  # The seam must classify errors so Arc 2's worker can choose snooze/cancel/
  # retry. Stubs return real sidecar-shaped bodies. This table is the
  # prerequisite for the §4b failure taxonomy; without it there is no taxonomy.

  defp stub_status(status, body) do
    Req.Test.stub(AiClient, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(body))
    end)
  end

  describe "response classification" do
    test "transport failure (connection refused) -> {:error, :unavailable}" do
      Req.Test.stub(AiClient, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)
      assert {:error, :unavailable} = AiClient.extract_receipt("x", @context)
    end

    test "transport failure (timeout) -> {:error, :unavailable}" do
      Req.Test.stub(AiClient, fn conn -> Req.Test.transport_error(conn, :timeout) end)
      assert {:error, :unavailable} = AiClient.extract_receipt("x", @context)
    end

    test "502 and 503 -> {:error, :unavailable} (sidecar down)" do
      for status <- [502, 503] do
        stub_status(status, %{"detail" => "Service Unavailable"})

        assert {:error, :unavailable} = AiClient.extract_receipt("x", @context),
               "Expected :unavailable for status #{status}"
      end
    end

    test "4xx -> {:error, {:bad_input, detail}} carrying the decoded body" do
      for status <- [400, 403, 404, 422, 429] do
        stub_status(status, %{"error" => "bad_request_#{status}"})

        assert {:error, {:bad_input, detail}} = AiClient.extract_receipt("x", @context),
               "Expected :bad_input for status #{status}"

        assert detail["error"] == "bad_request_#{status}"
      end
    end

    test "other 5xx -> {:error, {:transient, detail}} carrying the decoded body" do
      for status <- [500, 504] do
        stub_status(status, %{"error" => "server_error_#{status}"})

        assert {:error, {:transient, detail}} = AiClient.extract_receipt("x", @context),
               "Expected :transient for status #{status}"

        assert detail["error"] == "server_error_#{status}"
      end
    end

    test "200 -> {:ok, body} (unchanged)" do
      stub_status(200, %{"status" => "success", "payload" => %{"items" => []}})
      assert {:ok, body} = AiClient.extract_receipt("x", @context)
      assert body["payload"]["items"] == []
    end
  end

  # ── Property-Based Tests ────────────────────────────────────────

  describe "property: request_id uniqueness" do
    property "every request gets a unique request_id" do
      request_ids = :ets.new(:req_ids, [:bag, :public])

      Req.Test.stub(AiClient, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        :ets.insert(request_ids, {decoded["request_id"]})
        Req.Test.json(conn, %{"status" => "success", "payload" => %{}})
      end)

      check all(
              item_name <- string(:alphanumeric, min_length: 1, max_length: 50),
              max_runs: 20
            ) do
        AiClient.categorize_item(item_name, ["A"], @context)
      end

      all_ids = :ets.tab2list(request_ids) |> Enum.map(&elem(&1, 0))
      assert length(all_ids) == length(Enum.uniq(all_ids)), "request_ids must be unique"
      :ets.delete(request_ids)
    end
  end

  describe "property: context propagation" do
    property "tenant_id and user_id always appear in request body" do
      Req.Test.stub(AiClient, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert is_binary(decoded["tenant_id"])
        assert is_binary(decoded["user_id"])
        Req.Test.json(conn, %{"status" => "success", "payload" => %{}})
      end)

      check all(
              tenant <- string(:alphanumeric, min_length: 1, max_length: 36),
              user <- string(:alphanumeric, min_length: 1, max_length: 36),
              max_runs: 15
            ) do
        ctx = %{tenant_id: tenant, user_id: user}
        assert {:ok, _} = AiClient.categorize_item("item", ["Cat"], ctx)
      end
    end
  end
end
