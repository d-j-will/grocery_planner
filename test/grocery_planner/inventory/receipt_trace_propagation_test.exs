defmodule GroceryPlanner.Inventory.ReceiptTracePropagationTest do
  @moduledoc """
  Boundary test for web→worker trace propagation on the receipt pipeline
  (grocery_planner-23v; the "a web request traces through into an Oban worker"
  criterion of k9c/4x6.4).

  The property under test: uploading a receipt through the domain boundary
  (`ReceiptProcessor.upload/4`, the anti-corruption layer the LiveView calls)
  is traced, AND that trace context rides into the enqueued extract job's `meta`
  — which is exactly what `opentelemetry_oban` extracts on worker start
  (`job_handler.ex`: `:otel_propagator_text_map.extract(Map.to_list(job_meta))`).
  Without a span active during the enqueue, no traceparent is injected and the
  worker starts a fresh trace root — an operator can't follow an upload into its
  pipeline. That is the gap this test pins.

  Spans are captured with the in-memory `otel_exporter_pid` exporter (the test
  env sets `traces_exporter: :none`, so we swap the simple processor's exporter
  to send finished spans here as `{:span, span_record}`).
  """
  use GroceryPlanner.DataCase, async: false
  use Oban.Testing, repo: GroceryPlanner.Repo

  require Record

  alias GroceryPlanner.Inventory.ReceiptProcessor
  alias GroceryPlanner.Inventory.Receipts.ExtractWorker

  Record.defrecordp(
    :span,
    Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl")
  )

  @fixture "test/fixtures/sample_receipt.png"

  setup do
    # Swap the simple processor's exporter to send finished spans here. On exit,
    # point it at a draining sink rather than this (dying) pid — resetting to
    # `:none` warns because it is not a loadable exporter module.
    :otel_simple_processor.set_exporter(:otel_exporter_pid, self())

    on_exit(fn ->
      sink = spawn(fn -> Stream.repeatedly(fn -> receive(do: (_ -> :ok)) end) |> Stream.run() end)
      :otel_simple_processor.set_exporter(:otel_exporter_pid, sink)
    end)

    :ok
  end

  test "uploading a receipt propagates its trace context into the enqueued extract job" do
    {account, user} = create_account_and_user()

    # Copy the fixture to a temp path — upload/4 consumes (moves) the file.
    tmp = Path.join(System.tmp_dir!(), "sample_receipt_#{System.unique_integer([:positive])}.png")
    File.cp!(@fixture, tmp)
    file_params = %{path: tmp, client_name: "sample_receipt.png"}

    {:ok, _receipt} = ReceiptProcessor.upload(file_params, user, account)

    # 1. The upload operation must produce a span…
    assert_receive {:span, span(name: "receipt.upload", trace_id: trace_id)}, 2_000

    hex_trace = :io_lib.format("~32.16.0b", [trace_id]) |> List.to_string()

    # 2. …and its trace context must ride into the enqueued extract job so the
    #    worker (via opentelemetry_oban) inherits the same trace, not a fresh root.
    assert [job] = all_enqueued(worker: ExtractWorker)

    assert is_binary(job.meta["traceparent"]),
           "extract job carries no traceparent — enqueue ran outside a span"

    assert job.meta["traceparent"] =~ hex_trace,
           "extract job's traceparent is not rooted in the receipt.upload span"
  end
end
