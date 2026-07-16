defmodule GroceryPlanner.Inventory.ReceiptItem do
  @moduledoc """
  Represents an individual line item extracted from a receipt.
  """
  use Ash.Resource,
    domain: GroceryPlanner.Inventory,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "receipt_items"
    repo GroceryPlanner.Repo

    custom_indexes do
      # Idempotency belt-and-braces for the persist stage (AI-006 §3): an
      # extracted line's position uniquely keys it within a receipt, so a retried
      # persist can never duplicate items. Partial (line_no IS NOT NULL) so
      # manually-added review items — which have no position — are unconstrained.
      index [:receipt_id, :line_no],
        unique: true,
        where: "line_no IS NOT NULL",
        name: "receipt_items_receipt_id_line_no_index"
    end
  end

  code_interface do
    define :create
    define :read
    define :update
    define :destroy
    define :list_for_receipt, args: [:receipt_id]
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [
        :raw_name,
        :quantity,
        :unit,
        :unit_price,
        :total_price,
        :confidence,
        :final_name,
        :final_quantity,
        :final_unit,
        :line_no
      ]

      argument :receipt_id, :uuid, allow_nil?: false
      argument :account_id, :uuid, allow_nil?: false
      change manage_relationship(:receipt_id, :receipt, type: :append)
      change set_attribute(:account_id, arg(:account_id))
    end

    update :update do
      accept [
        :final_name,
        :final_quantity,
        :final_unit,
        :status,
        :user_corrected,
        :grocery_item_id,
        :match_confidence,
        :inventory_entry_id
      ]

      require_atomic? false
    end

    read :list_for_receipt do
      argument :receipt_id, :uuid, allow_nil?: false
      filter expr(receipt_id == ^arg(:receipt_id))
      # Extraction order (matches the paper receipt); manually-added items
      # (line_no IS NULL) sort last.
      prepare build(sort: [line_no: :asc_nils_last])
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if relates_to_actor_via([:receipt, :account, :memberships, :user])
    end

    policy action_type(:create) do
      authorize_if always()
    end

    policy action_type([:update, :destroy]) do
      authorize_if relates_to_actor_via([:receipt, :account, :memberships, :user])
    end
  end

  multitenancy do
    strategy :attribute
    attribute :account_id
  end

  attributes do
    uuid_primary_key :id

    attribute :raw_name, :string do
      allow_nil? false
      public? true
    end

    # Position of this line in the extraction (0-based), or nil for items added
    # manually during review. The (receipt_id, line_no) unique index makes the
    # persist stage idempotent and gives the review screen a stable order that
    # matches the paper receipt (AI-006 §3).
    attribute :line_no, :integer do
      public? true
    end

    attribute :quantity, :decimal do
      public? true
    end

    attribute :unit, :string do
      public? true
    end

    attribute :unit_price, AshMoney.Types.Money do
      public? true
    end

    attribute :total_price, AshMoney.Types.Money do
      public? true
    end

    attribute :confidence, :float do
      public? true
    end

    attribute :grocery_item_id, :uuid do
      public? true
    end

    attribute :match_confidence, :float do
      public? true
    end

    attribute :user_corrected, :boolean do
      default false
      public? true
    end

    attribute :final_name, :string do
      public? true
    end

    attribute :final_quantity, :decimal do
      public? true
    end

    attribute :final_unit, :string do
      public? true
    end

    attribute :status, :atom do
      constraints one_of: [:pending, :confirmed, :skipped]
      default :pending
      allow_nil? false
      public? true
    end

    attribute :inventory_entry_id, :uuid do
      public? true
    end

    attribute :account_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :receipt_id, :uuid do
      allow_nil? false
      public? true
    end

    create_timestamp :created_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :receipt, GroceryPlanner.Inventory.Receipt do
      allow_nil? false
      attribute_writable? true
    end

    belongs_to :account, GroceryPlanner.Accounts.Account do
      allow_nil? false
      attribute_writable? true
    end

    belongs_to :grocery_item, GroceryPlanner.Inventory.GroceryItem do
      attribute_writable? true
    end

    belongs_to :inventory_entry, GroceryPlanner.Inventory.InventoryEntry do
      attribute_writable? true
    end
  end
end
