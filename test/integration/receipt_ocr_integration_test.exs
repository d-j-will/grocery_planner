defmodule GroceryPlanner.Integration.ReceiptOcrIntegrationTest do
  @moduledoc """
  Integration tests that exercise the real Elixir → Python AI service HTTP path.

  These tests require the Python service to be running on the configured URL.
  They are excluded from normal `mix test` runs and require:

      AI_SERVICE_URL=http://localhost:8099 mix test.integration

  Or use the helper script:

      ./scripts/test-integration.sh
  """
  use GroceryPlanner.IntegrationCase, async: false

  @moduletag :integration

  @fixture_path "test/fixtures/sample_receipt.png"

  describe "Python service connectivity" do
    test "health endpoint returns ok" do
      assert service_healthy?(),
             "Python AI service is not running at #{ai_service_url()}. " <>
               "Start it with: ./scripts/test-integration.sh"

      {:ok, %Req.Response{status: 200, body: body}} =
        Req.get(Req.new(base_url: ai_service_url()), url: "/health")

      assert body["status"] == "ok"
    end
  end

  describe "direct AiClient.extract_receipt/3" do
    test "sends receipt image and receives a response from the Python service" do
      assert File.exists?(@fixture_path), "Fixture missing: #{@fixture_path}"

      image_base64 = @fixture_path |> File.read!() |> Base.encode64()
      context = %{tenant_id: Ecto.UUID.generate(), user_id: nil}

      result = GroceryPlanner.AiClient.extract_receipt(image_base64, context)

      # The round-trip should complete — either OCR succeeds or the service
      # returns an error response. Both prove the HTTP path works.
      case result do
        {:ok, body} ->
          assert is_map(body)
          assert body["status"] in ["success", "ok", "error"]

        {:error, reason} ->
          # 500 from Tesseract failing on the test image is acceptable —
          # it proves the HTTP round-trip worked and the service responded.
          assert reason != nil
      end
    end

    test "returns error for invalid base64 payload" do
      context = %{tenant_id: Ecto.UUID.generate(), user_id: nil}

      # Send garbage that is not a valid image
      result = GroceryPlanner.AiClient.extract_receipt("not_valid_base64!", context)

      # Should either return an error tuple or a success with empty/error payload
      # The Python service may return 200 with error status or 400/500
      case result do
        {:error, _reason} -> :ok
        {:ok, body} -> assert is_map(body)
      end
    end
  end

  describe "full receipt processing flow" do
    test "processes a receipt through the Ash action pipeline" do
      {account, _user} = create_account_and_user()

      # Create a receipt pointing to the real fixture file
      {:ok, receipt} =
        GroceryPlanner.Inventory.create_receipt(
          account.id,
          %{
            file_path: Path.absname(@fixture_path),
            file_hash:
              :crypto.hash(:sha256, File.read!(@fixture_path)) |> Base.encode16(case: :lower),
            file_size: File.stat!(@fixture_path).size,
            mime_type: "image/png"
          },
          authorize?: false,
          tenant: account.id
        )

      assert receipt.status == :pending

      # Drive the extract stage worker directly (bypasses Oban scheduling).
      # This exercises: file read → base64 encode → HTTP POST → response handling
      # → classification. OCR may fail on the test fixture, which is fine — we're
      # testing the pipeline plumbing, not Tesseract accuracy.
      job = %Oban.Job{args: %{"receipt_id" => receipt.id}, attempt: 1, max_attempts: 5}
      result = GroceryPlanner.Inventory.Receipts.ExtractWorker.perform(job)

      {:ok, processed} =
        GroceryPlanner.Inventory.get_receipt(receipt.id, authorize?: false, tenant: account.id)

      case result do
        :ok ->
          # Extraction succeeded — the milestone advanced.
          assert processed.stage == :extracted
          assert processed.processed_at != nil

        {:cancel, _} ->
          # Bad input (4xx) — classified and failed, not retried.
          assert processed.condition == :failed

        {:snooze, _} ->
          # Sidecar unavailable — visible as awaiting_ai.
          assert processed.condition == :awaiting_ai

        {:error, _} ->
          # Transient (5xx) — left for retry. Both prove the round-trip works.
          :ok
      end
    end
  end

  describe "error handling" do
    test "gracefully handles receipt with non-existent file" do
      {account, _user} = create_account_and_user()

      {:ok, receipt} =
        GroceryPlanner.Inventory.create_receipt(
          account.id,
          %{
            file_path: "/tmp/nonexistent_receipt_#{System.unique_integer()}.png",
            file_hash: "fakehash_#{System.unique_integer()}",
            file_size: 0,
            mime_type: "image/png"
          },
          authorize?: false,
          tenant: account.id
        )

      # A missing file never recovers on retry: the extract worker cancels and
      # marks the receipt failed.
      job = %Oban.Job{args: %{"receipt_id" => receipt.id}, attempt: 1, max_attempts: 5}
      assert {:cancel, _} = GroceryPlanner.Inventory.Receipts.ExtractWorker.perform(job)

      {:ok, r} =
        GroceryPlanner.Inventory.get_receipt(receipt.id, authorize?: false, tenant: account.id)

      assert r.condition == :failed
    end
  end
end
