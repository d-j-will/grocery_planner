defmodule GroceryPlanner.PromEx.ReceiptPluginTest do
  @moduledoc """
  Boundary tests for the receipt outage-signal metric source: does the aggregate
  reflect real DB state, and does execute emit a gauge per condition (including
  the zeros that let a drained gauge report 0)?
  """
  use GroceryPlanner.DataCase, async: true

  import GroceryPlanner.InventoryTestHelpers

  alias GroceryPlanner.PromEx.ReceiptPlugin

  @event [:prom_ex, :plugin, :receipt, :condition, :count]

  defp new_receipt(account) do
    {:ok, receipt} =
      GroceryPlanner.Inventory.create_receipt(
        account.id,
        %{
          file_path: "/tmp/#{Ecto.UUID.generate()}.png",
          file_hash: Base.encode16(:crypto.hash(:sha256, Ecto.UUID.generate())),
          file_size: 100,
          mime_type: "image/png"
        },
        authorize?: false,
        tenant: account.id
      )

    receipt
  end

  # Transition via the same production actions the pipeline workers use, never
  # by hand-setting the column.
  defp transition!(receipt, _account, :ok), do: receipt

  defp transition!(receipt, account, :awaiting_ai) do
    receipt
    |> Ash.Changeset.for_update(:mark_awaiting_ai, %{}, tenant: account.id, authorize?: false)
    |> Ash.update!()
  end

  defp transition!(receipt, account, :failed) do
    receipt
    |> Ash.Changeset.for_update(:mark_failed, %{failure_reason: "sidecar down"},
      tenant: account.id,
      authorize?: false
    )
    |> Ash.update!()
  end

  defp seed(account, condition, n) do
    for _ <- 1..n, do: account |> new_receipt() |> transition!(account, condition)
  end

  describe "receipt_condition_counts/0" do
    test "counts receipts grouped by condition, across tenants" do
      {a1, _} = create_account_and_user()
      {a2, _} = create_account_and_user()

      seed(a1, :ok, 3)
      seed(a1, :awaiting_ai, 2)
      seed(a2, :awaiting_ai, 1)
      seed(a2, :failed, 1)

      counts = ReceiptPlugin.receipt_condition_counts()

      assert counts[:ok] == 3
      # the outage signal aggregates across both households
      assert counts[:awaiting_ai] == 3
      assert counts[:failed] == 1
    end

    test "is an empty map when there are no receipts" do
      assert ReceiptPlugin.receipt_condition_counts() == %{}
    end
  end

  describe "execute_receipt_metrics/0" do
    test "emits a gauge per known condition, including zeros so the gauge drains" do
      {account, _} = create_account_and_user()
      seed(account, :awaiting_ai, 2)

      handler_id = "receipt-plugin-test-#{System.unique_integer()}"
      test_pid = self()

      :telemetry.attach_many(
        handler_id,
        [@event],
        fn event, measurements, metadata, _ ->
          send(test_pid, {event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert :ok = ReceiptPlugin.execute_receipt_metrics()

      assert_received {@event, %{count: 2}, %{condition: :awaiting_ai}}
      # nothing failed / ok, but the series are still emitted at 0
      assert_received {@event, %{count: 0}, %{condition: :failed}}
      assert_received {@event, %{count: 0}, %{condition: :ok}}
    end
  end
end
