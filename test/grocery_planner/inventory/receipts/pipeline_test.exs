defmodule GroceryPlanner.Inventory.Receipts.PipelineTest do
  @moduledoc """
  System-boundary tests for the staged receipt pipeline (AI-006 Arc 2). These
  drive the REAL workers with a stubbed sidecar — never the parse helpers
  directly — because the whole point of the rework is behaviour the old
  function-level tests couldn't see (the app called a different endpoint than the
  tests exercised). Covers the three `cxk` regressions and the §4b taxonomy.
  """
  use GroceryPlanner.DataCase, async: false
  use Oban.Testing, repo: GroceryPlanner.Repo

  alias GroceryPlanner.Inventory
  alias GroceryPlanner.Inventory.Receipts.Pipeline

  alias GroceryPlanner.Inventory.Receipts.{
    ExtractWorker,
    PersistWorker,
    MatchWorker,
    CategoriseWorker
  }

  @payload %{
    "currency" => "USD",
    "merchant" => "Store",
    "date" => "2026-02-01",
    "total" => 6.49,
    "raw_ocr_text" => "STORE\nMILK\nBREAD",
    "overall_confidence" => 0.9,
    "model_version" => "tesseract-5.3.0",
    "processing_time_ms" => 100.0,
    "items" => [
      %{
        "name" => "Milk",
        "quantity" => 1,
        "unit" => "each",
        "price" => 3.99,
        "confidence" => 0.9
      },
      %{
        "name" => "Bread",
        "quantity" => 1,
        "unit" => "each",
        "price" => 2.50,
        "confidence" => 0.8
      }
    ]
  }

  setup do
    {account, _user} = create_account_and_user()
    %{account: account}
  end

  describe "happy path" do
    test "extract -> persist -> match advances the milestone and orders items by line_no",
         %{account: account} do
      stub_success(@payload)
      receipt = receipt_with_file(account)

      assert :ok = ExtractWorker.perform(job(receipt))
      r1 = reload(receipt, account)
      assert r1.stage == :extracted
      assert r1.condition == :ok
      assert r1.merchant_name == "Store"
      assert r1.raw_extraction["merchant"] == "Store"
      # The wire between stages: extract must enqueue persist (right worker, right
      # args). Hand-driving perform/1 would mask a broken enqueue — the exact
      # AI-006 failure mode.
      assert_enqueued(worker: PersistWorker, args: %{receipt_id: receipt.id})

      assert :ok = PersistWorker.perform(job(receipt))
      r2 = reload(receipt, account)
      assert r2.stage == :items_created
      assert_enqueued(worker: MatchWorker, args: %{receipt_id: receipt.id})

      {:ok, items} =
        Inventory.list_receipt_items_for_receipt(receipt.id,
          authorize?: false,
          tenant: account.id
        )

      # list_for_receipt sorts by line_no — items come back in receipt order.
      assert Enum.map(items, & &1.line_no) == [0, 1]
      assert Enum.map(items, & &1.raw_name) == ["Milk", "Bread"]

      assert :ok = MatchWorker.perform(job(receipt))
      r3 = reload(receipt, account)
      assert r3.stage == :ready_for_review
      assert r3.condition == :ok
      assert_enqueued(worker: CategoriseWorker, args: %{receipt_id: receipt.id})
    end

    test "end-to-end via real Oban queues: upload enqueues extract, draining reaches review",
         %{account: account} do
      stub_success(@payload)
      receipt = receipt_with_file(account)

      # Enqueue the way ReceiptProcessor.upload does — nothing hand-wired.
      Pipeline.enqueue_extract(receipt.id)
      assert_enqueued(worker: ExtractWorker, args: %{receipt_id: receipt.id})

      # Drain the real queues in pipeline order. drain_queue runs jobs inline in
      # this process, so the process-scoped sidecar stub applies, and each stage
      # enqueues the next into its configured queue — this asserts the queue names
      # and arg serialization actually connect.
      assert %{success: 1} = Oban.drain_queue(queue: :ai_jobs)
      assert %{success: 1} = Oban.drain_queue(queue: :default)
      assert %{success: 1} = Oban.drain_queue(queue: :matching)
      # categorise lands back on :ai_jobs (degradable, always succeeds/no-ops).
      Oban.drain_queue(queue: :ai_jobs)

      r = reload(receipt, account)
      assert r.stage == :ready_for_review
      assert r.condition == :ok

      {:ok, items} =
        Inventory.list_receipt_items_for_receipt(receipt.id,
          authorize?: false,
          tenant: account.id
        )

      assert length(items) == 2
    end
  end

  describe "reconciler" do
    test "reconcile action re-enqueues the worker for the receipt's current stage",
         %{account: account} do
      # A fresh receipt stranded at :pending should get extract re-enqueued.
      receipt = receipt_with_file(account)

      {:ok, _} =
        receipt
        |> Ash.Changeset.for_update(:reconcile, %{}, authorize?: false, tenant: account.id)
        |> Ash.update()

      assert_enqueued(worker: ExtractWorker, args: %{receipt_id: receipt.id})
    end

    test "enqueue_for_stage maps each stage to its worker and skips terminal stages",
         %{account: account} do
      receipt = receipt_with_file(account)

      assert {:ok, _} = Pipeline.enqueue_for_stage(%{receipt | stage: :pending})
      assert_enqueued(worker: ExtractWorker, args: %{receipt_id: receipt.id})

      assert {:ok, _} = Pipeline.enqueue_for_stage(%{receipt | stage: :extracted})
      assert_enqueued(worker: PersistWorker, args: %{receipt_id: receipt.id})

      assert {:ok, _} = Pipeline.enqueue_for_stage(%{receipt | stage: :items_created})
      assert_enqueued(worker: MatchWorker, args: %{receipt_id: receipt.id})

      # Terminal — nothing enqueued.
      assert :ok = Pipeline.enqueue_for_stage(%{receipt | stage: :ready_for_review})
    end
  end

  describe "cxk: idempotency" do
    test "re-running persist does not duplicate items (postcondition no-op)", %{account: account} do
      stub_success(@payload)
      receipt = receipt_with_file(account)
      ExtractWorker.perform(job(receipt))

      assert :ok = PersistWorker.perform(job(receipt))
      # Simulate commit-then-crash retry: the same job runs again.
      assert :ok = PersistWorker.perform(job(receipt))

      {:ok, items} =
        Inventory.list_receipt_items_for_receipt(receipt.id,
          authorize?: false,
          tenant: account.id
        )

      assert length(items) == 2
    end

    test "extract never re-calls the sidecar once the milestone is reached",
         %{account: account} do
      test_pid = self()

      Req.Test.stub(GroceryPlanner.AiClient, fn conn ->
        send(test_pid, :sidecar_called)
        Req.Test.json(conn, %{"status" => "success", "payload" => @payload})
      end)

      receipt = receipt_with_file(account)

      assert :ok = ExtractWorker.perform(job(receipt))
      assert_received :sidecar_called

      # Retry after :extracted — the postcondition short-circuits, no OCR re-run.
      assert :ok = ExtractWorker.perform(job(receipt))
      refute_received :sidecar_called
    end
  end

  describe "cxk / §4b: failure taxonomy" do
    test "sidecar down -> snooze + condition :awaiting_ai, no milestone burned",
         %{account: account} do
      Req.Test.stub(GroceryPlanner.AiClient, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      receipt = receipt_with_file(account)

      assert {:snooze, _} = ExtractWorker.perform(job(receipt))

      r = reload(receipt, account)
      assert r.condition == :awaiting_ai
      # Not failed, and the milestone did not advance — snooze preserves the budget.
      assert r.stage == :pending
    end

    test "bad input (4xx) -> cancel + condition :failed with a reason", %{account: account} do
      stub_status(422, %{"error" => "unreadable image"})
      receipt = receipt_with_file(account)

      assert {:cancel, _} = ExtractWorker.perform(job(receipt))

      r = reload(receipt, account)
      assert r.condition == :failed
      assert r.failure_reason =~ "rejected"
    end

    test "transient (5xx) -> error (left for retry), condition unchanged", %{account: account} do
      stub_status(500, %{"error" => "boom"})
      receipt = receipt_with_file(account)

      assert {:error, _} = ExtractWorker.perform(job(receipt))

      r = reload(receipt, account)
      assert r.condition == :ok
      assert r.stage == :pending
    end

    test "missing file -> cancel + condition :failed", %{account: account} do
      {:ok, receipt} =
        Inventory.create_receipt(
          account.id,
          %{
            file_path: "/tmp/does_not_exist_#{System.unique_integer([:positive])}.png",
            file_hash: "missing_#{System.unique_integer([:positive])}",
            file_size: 0,
            mime_type: "image/png"
          },
          authorize?: false,
          tenant: account.id
        )

      assert {:cancel, _} = ExtractWorker.perform(job(receipt))
      assert reload(receipt, account).condition == :failed
    end
  end

  # --- helpers ---------------------------------------------------------------

  defp job(receipt, attempt \\ 1) do
    %Oban.Job{args: %{"receipt_id" => receipt.id}, attempt: attempt, max_attempts: 5}
  end

  defp stub_success(payload) do
    Req.Test.stub(GroceryPlanner.AiClient, fn conn ->
      Req.Test.json(conn, %{
        "request_id" => "req_test",
        "status" => "success",
        "payload" => payload
      })
    end)
  end

  defp stub_status(status, body) do
    Req.Test.stub(GroceryPlanner.AiClient, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(body))
    end)
  end

  defp receipt_with_file(account) do
    path = Path.join(System.tmp_dir!(), "pipe_#{System.unique_integer([:positive])}.png")
    File.write!(path, "fake png bytes")
    on_exit(fn -> File.rm(path) end)

    {:ok, receipt} =
      Inventory.create_receipt(
        account.id,
        %{
          file_path: path,
          file_hash: "hash_#{System.unique_integer([:positive])}",
          file_size: 14,
          mime_type: "image/png"
        },
        authorize?: false,
        tenant: account.id
      )

    receipt
  end

  defp reload(receipt, account) do
    {:ok, r} = Inventory.get_receipt(receipt.id, authorize?: false, tenant: account.id)
    r
  end
end
