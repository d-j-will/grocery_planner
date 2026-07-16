defmodule GroceryPlanner.Inventory.Receipt do
  @moduledoc """
  Represents an uploaded receipt with OCR extraction results.

  ## State model (AI-006 Arc 2)

  Two orthogonal axes replace the old overloaded `status`:

    * `stage` — the furthest **durable milestone** reached, monotonic:
      `:pending -> :extracted -> :items_created -> :ready_for_review -> :confirmed`.
      It records *where the receipt got*, never in-flight activity (Oban already
      knows what is executing).
    * `condition` — how the receipt is *faring*: `:ok` / `:awaiting_ai` / `:failed`.
      Orthogonal and resettable. `failure_reason` is set iff `condition == :failed`.

  The pipeline runs as hand-written Oban workers (see
  `GroceryPlanner.Inventory.Receipts.*Worker`), not AshOban triggers: AshOban's
  generated worker cannot express the §4b failure taxonomy (no action-driven
  snooze/cancel). The workers advance `stage` via the `mark_*` actions below, each
  idempotent (postcondition-checked) and single-transaction. `condition` is display
  and alerting only — nothing reads it to make a scheduling decision.

  The `:reconcile` trigger is the one AshOban trigger: a scheduled cross-tenant scan
  for records stranded at a non-terminal stage (its sweet spot).
  """
  use Ash.Resource,
    domain: GroceryPlanner.Inventory,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshOban]

  postgres do
    table "receipts"
    repo GroceryPlanner.Repo
  end

  oban do
    triggers do
      # Safety net for receipts stranded at a non-terminal stage (e.g. an Oban
      # job lost to a container restart that Lifeline didn't rescue). Re-enqueues
      # the worker for the current stage. Reads `stage` only — never `condition` —
      # to decide what to enqueue; `condition != :failed` just skips deliberately
      # failed records. `stream_with: :full_read` because the `where` depends on
      # time (:keyset would drop records between batches — fails intermittently,
      # not loudly).
      trigger :reconcile do
        action :reconcile
        queue(:default)
        scheduler_cron("*/5 * * * *")
        stream_with :full_read

        where expr(
                stage in [:pending, :extracted, :items_created] and condition != :failed and
                  updated_at < ago(5, :minute)
              )

        read_action :reconcile_read
        worker_read_action(:reconcile_read)
        use_tenant_from_record?(true)
        max_attempts(1)
        scheduler_module_name(GroceryPlanner.Inventory.Receipt.AshOban.Scheduler.Reconcile)
        worker_module_name(GroceryPlanner.Inventory.Receipt.AshOban.Worker.Reconcile)
      end
    end
  end

  code_interface do
    define :create
    define :read
    define :list_all
    define :get_by_id, action: :read, get_by: [:id]
    define :update
    define :destroy
    define :find_by_hash, args: [:file_hash]
    define :mark_extracted
    define :mark_items_created
    define :mark_ready_for_review
    define :mark_confirmed
    define :mark_failed
    define :mark_awaiting_ai
    define :clear_condition
  end

  actions do
    defaults [:read, :destroy]

    read :list_all do
      prepare build(sort: [created_at: :desc])
    end

    # Cross-tenant read for the reconciler scheduler. allow_global so the single
    # scheduler query spans every account; `use_tenant_from_record?` then sets the
    # tenant per record for the worker.
    read :reconcile_read do
      multitenancy :allow_global
      # AshOban requires the scheduler read action to declare keyset capability,
      # but the trigger sets `stream_with :full_read` — because the `where`
      # depends on time, keyset would drop records between batches (AI-006 §3
      # gotcha). Declared here, overridden at runtime.
      pagination keyset?: true, required?: false
    end

    # Cross-tenant read used by the pipeline workers to load a record globally
    # (the worker sets the tenant from the record's account_id).
    read :worker_read do
      multitenancy :allow_global
    end

    read :find_by_hash do
      argument :file_hash, :string, allow_nil?: false
      filter expr(file_hash == ^arg(:file_hash))
    end

    create :create do
      accept [:file_path, :file_hash, :file_size, :mime_type]
      argument :account_id, :uuid, allow_nil?: false
      change manage_relationship(:account_id, :account, type: :append)
    end

    update :update do
      accept [
        :stage,
        :condition,
        :failure_reason,
        :merchant_name,
        :purchase_date,
        :total_amount,
        :raw_ocr_text,
        :extraction_confidence,
        :model_version,
        :processed_at,
        :processing_time_ms
      ]

      require_atomic? false
    end

    # --- Milestone advances (called by the pipeline workers) ---

    # extract stage: write the receipt metadata + raw payload and advance to
    # :extracted in one action. Clears any prior failure/awaiting condition.
    update :mark_extracted do
      accept [
        :raw_extraction,
        :merchant_name,
        :purchase_date,
        :total_amount,
        :raw_ocr_text,
        :extraction_confidence,
        :model_version,
        :processing_time_ms,
        :processed_at
      ]

      require_atomic? false
      change set_attribute(:stage, :extracted)
      change set_attribute(:condition, :ok)
      change set_attribute(:failure_reason, nil)
    end

    update :mark_items_created do
      require_atomic? false
      change set_attribute(:stage, :items_created)
      change set_attribute(:condition, :ok)
    end

    update :mark_ready_for_review do
      require_atomic? false
      change set_attribute(:stage, :ready_for_review)
      change set_attribute(:condition, :ok)
    end

    update :mark_confirmed do
      require_atomic? false
      change set_attribute(:stage, :confirmed)
      change set_attribute(:condition, :ok)
    end

    update :mark_failed do
      accept [:failure_reason]
      require_atomic? false
      change set_attribute(:condition, :failed)
    end

    update :mark_awaiting_ai do
      require_atomic? false
      change set_attribute(:condition, :awaiting_ai)
    end

    update :clear_condition do
      require_atomic? false
      change set_attribute(:condition, :ok)
      change set_attribute(:failure_reason, nil)
    end

    # Reconciler action: touch the record (bumps updated_at so it leaves the
    # stranded window) and re-enqueue the worker for its current stage.
    update :reconcile do
      require_atomic? false
      change GroceryPlanner.Inventory.Changes.ReconcileReceipt
    end
  end

  policies do
    bypass AshOban.Checks.AshObanInteraction do
      authorize_if always()
    end

    policy action_type(:read) do
      authorize_if relates_to_actor_via([:account, :memberships, :user])
    end

    policy action_type(:create) do
      authorize_if always()
    end

    policy action_type([:update, :destroy]) do
      authorize_if relates_to_actor_via([:account, :memberships, :user])
    end
  end

  validations do
    validate present(:failure_reason),
      where: [attribute_equals(:condition, :failed)],
      message: "is required when condition is :failed"

    validate attribute_does_not_equal(:stage, :confirmed),
      where: [attribute_equals(:condition, :failed)],
      message: "a failed receipt cannot also be confirmed"
  end

  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  attributes do
    uuid_primary_key :id

    attribute :file_path, :string do
      allow_nil? false
      public? true
    end

    attribute :file_hash, :string do
      public? true
    end

    attribute :file_size, :integer do
      public? true
    end

    attribute :mime_type, :string do
      public? true
    end

    # Furthest durable milestone reached. Monotonic — only ever advances (the
    # workers' postcondition checks enforce this; there is no DB-level guard so a
    # future explicit rescan can reset it).
    attribute :stage, :atom do
      constraints one_of: [:pending, :extracted, :items_created, :ready_for_review, :confirmed]
      default :pending
      allow_nil? false
      public? true
    end

    # How the receipt is faring. Orthogonal to stage, resettable. Display and
    # alerting only — never read to make a scheduling decision.
    attribute :condition, :atom do
      constraints one_of: [:ok, :awaiting_ai, :failed]
      default :ok
      allow_nil? false
      public? true
    end

    attribute :failure_reason, :string do
      public? true
    end

    # Inter-stage handoff: the flat extraction payload the extract stage wrote and
    # the persist stage reads. Oban args carry only receipt_id — a large blob in
    # oban_jobs.args is how base64 ended up in SQLite (AI-006 §2b). Also replaces
    # the sidecar's ai_artifacts table (Arc 4).
    attribute :raw_extraction, :map do
      public? true
    end

    attribute :merchant_name, :string do
      public? true
    end

    attribute :purchase_date, :date do
      public? true
    end

    attribute :total_amount, AshMoney.Types.Money do
      public? true
    end

    attribute :raw_ocr_text, :string do
      public? true
    end

    attribute :extraction_confidence, :float do
      public? true
    end

    attribute :model_version, :string do
      public? true
    end

    attribute :processed_at, :utc_datetime do
      public? true
    end

    attribute :processing_time_ms, :integer do
      public? true
    end

    attribute :account_id, :uuid do
      allow_nil? false
      public? true
    end

    create_timestamp :created_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :account, GroceryPlanner.Accounts.Account do
      allow_nil? false
      attribute_writable? true
    end

    has_many :receipt_items, GroceryPlanner.Inventory.ReceiptItem
  end
end
