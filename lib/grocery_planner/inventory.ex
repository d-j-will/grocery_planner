defmodule GroceryPlanner.Inventory do
  @moduledoc false
  use Ash.Domain,
    extensions: [AshJsonApi.Domain]

  json_api do
    prefix "/api/json"
  end

  resources do
    resource GroceryPlanner.Inventory.Category do
      define :create_category, action: :create, args: [:account_id]
      define :list_categories, action: :read
      define :get_category, action: :read, get_by: [:id]
      define :update_category, action: :update
      define :destroy_category, action: :destroy
    end

    resource GroceryPlanner.Inventory.StorageLocation do
      define :create_storage_location, action: :create, args: [:account_id]
      define :list_storage_locations, action: :read
      define :list_storage_locations_sorted, action: :list_all_sorted
      define :get_storage_location, action: :read, get_by: [:id]
      define :update_storage_location, action: :update
      define :destroy_storage_location, action: :destroy
    end

    resource GroceryPlanner.Inventory.GroceryItem do
      define :create_grocery_item, action: :create, args: [:account_id]
      define :list_grocery_items, action: :read
      define :list_items_with_tags, action: :list_with_tags, args: [:filter_tag_ids]
      define :get_grocery_item, action: :read, get_by: [:id]
      define :get_item_by_name, action: :by_name, args: [:name], get?: true
      define :update_grocery_item, action: :update
      define :destroy_grocery_item, action: :destroy
      define :sync_grocery_items, action: :sync, args: [:since]
      define :pull_grocery_items, action: :sync, args: [:since, :limit]
    end

    resource GroceryPlanner.Inventory.InventoryEntry do
      define :create_inventory_entry, action: :create, args: [:account_id, :grocery_item_id]
      define :list_inventory_entries, action: :read
      define :list_inventory_entries_filtered, action: :list_filtered
      define :get_inventory_entry, action: :read, get_by: [:id]
      define :update_inventory_entry, action: :update
      define :destroy_inventory_entry, action: :destroy
      define :sync_inventory_entries, action: :sync, args: [:since]
      define :pull_inventory_entries, action: :sync, args: [:since, :limit]
    end

    resource GroceryPlanner.Inventory.GroceryItemTag do
      define :create_grocery_item_tag, action: :create, args: [:account_id]
      define :list_grocery_item_tags, action: :read
      define :get_grocery_item_tag, action: :read, get_by: [:id]
      define :update_grocery_item_tag, action: :update
      define :destroy_grocery_item_tag, action: :destroy
    end

    resource GroceryPlanner.Inventory.GroceryItemTagging do
      define :create_grocery_item_tagging, action: :create
      define :list_grocery_item_taggings, action: :read
      define :list_taggings_for_item, action: :by_item, args: [:grocery_item_id]
      define :get_tagging, action: :by_item_and_tag, args: [:grocery_item_id, :tag_id], get?: true
      define :destroy_grocery_item_tagging, action: :destroy
    end

    resource GroceryPlanner.Inventory.Receipt do
      define :create_receipt, action: :create, args: [:account_id]
      define :list_receipts, action: :list_all
      define :get_receipt, action: :read, get_by: [:id]
      define :find_receipt_by_hash, action: :find_by_hash, args: [:file_hash], get?: true
      define :update_receipt, action: :update
      define :clear_condition, action: :clear_condition
      define :mark_items_created, action: :mark_items_created
      define :mark_ready_for_review, action: :mark_ready_for_review
      define :mark_confirmed, action: :mark_confirmed
      define :destroy_receipt, action: :destroy
    end

    resource GroceryPlanner.Inventory.ReceiptItem do
      define :create_receipt_item, action: :create, args: [:receipt_id, :account_id]
      define :list_receipt_items, action: :read
      define :list_receipt_items_for_receipt, action: :list_for_receipt, args: [:receipt_id]
      define :get_receipt_item, action: :read, get_by: [:id]
      define :update_receipt_item, action: :update
      define :destroy_receipt_item, action: :destroy
    end
  end
end
