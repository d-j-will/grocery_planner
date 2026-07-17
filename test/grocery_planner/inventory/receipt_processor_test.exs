defmodule GroceryPlanner.Inventory.ReceiptProcessorTest do
  use GroceryPlanner.DataCase, async: true

  alias GroceryPlanner.Inventory.ReceiptProcessor
  alias GroceryPlanner.Inventory

  setup do
    {account, user} = create_account_and_user()
    %{user: user, account: account}
  end

  describe "compute_file_hash/1" do
    test "computes SHA256 hash of file" do
      # Create a temp file
      path = Path.join(System.tmp_dir!(), "test_receipt_#{System.unique_integer()}.txt")
      File.write!(path, "test receipt content")

      hash = ReceiptProcessor.compute_file_hash(path)

      assert is_binary(hash)
      assert String.length(hash) == 64
      # SHA256 hex = 64 chars
      assert hash == ReceiptProcessor.compute_file_hash(path)
      # deterministic

      File.rm!(path)
    end

    test "different files produce different hashes" do
      path1 = Path.join(System.tmp_dir!(), "test_receipt_a_#{System.unique_integer()}.txt")
      path2 = Path.join(System.tmp_dir!(), "test_receipt_b_#{System.unique_integer()}.txt")
      File.write!(path1, "content A")
      File.write!(path2, "content B")

      assert ReceiptProcessor.compute_file_hash(path1) !=
               ReceiptProcessor.compute_file_hash(path2)

      File.rm!(path1)
      File.rm!(path2)
    end

    test "same content produces same hash" do
      path1 = Path.join(System.tmp_dir!(), "test_receipt_1_#{System.unique_integer()}.txt")
      path2 = Path.join(System.tmp_dir!(), "test_receipt_2_#{System.unique_integer()}.txt")
      File.write!(path1, "identical content")
      File.write!(path2, "identical content")

      assert ReceiptProcessor.compute_file_hash(path1) ==
               ReceiptProcessor.compute_file_hash(path2)

      File.rm!(path1)
      File.rm!(path2)
    end
  end

  describe "store_file/1" do
    test "stores file and returns metadata" do
      path = Path.join(System.tmp_dir!(), "test_upload_#{System.unique_integer()}.jpg")
      File.write!(path, "fake image data")

      file_params = %{path: path, client_name: "receipt.jpg"}

      assert {:ok, dest_path, hash, size, mime} = ReceiptProcessor.store_file(file_params)
      assert String.ends_with?(dest_path, ".jpg")
      assert is_binary(hash)
      assert String.length(hash) == 64
      assert size > 0
      assert mime == "image/jpeg"

      # Verify file was copied
      assert File.exists?(dest_path)

      # Cleanup
      File.rm(dest_path)
      File.rm!(path)
    end

    test "stores PNG files with correct mime type" do
      path = Path.join(System.tmp_dir!(), "test_upload_#{System.unique_integer()}.png")
      File.write!(path, "fake png data")

      file_params = %{path: path, client_name: "receipt.png"}

      assert {:ok, dest_path, _hash, _size, mime} = ReceiptProcessor.store_file(file_params)
      assert String.ends_with?(dest_path, ".png")
      assert mime == "image/png"

      # Cleanup
      File.rm(dest_path)
      File.rm!(path)
    end

    test "stores HEIC files with correct mime type" do
      path = Path.join(System.tmp_dir!(), "test_upload_#{System.unique_integer()}.heic")
      File.write!(path, "fake heic data")

      file_params = %{path: path, client_name: "receipt.HEIC"}

      assert {:ok, dest_path, _hash, _size, mime} = ReceiptProcessor.store_file(file_params)
      assert String.ends_with?(dest_path, ".HEIC")
      assert mime == "image/heic"

      # Cleanup
      File.rm(dest_path)
      File.rm!(path)
    end

    test "stores PDF files with correct mime type" do
      path = Path.join(System.tmp_dir!(), "test_upload_#{System.unique_integer()}.pdf")
      File.write!(path, "fake pdf data")

      file_params = %{path: path, client_name: "receipt.pdf"}

      assert {:ok, dest_path, _hash, _size, mime} = ReceiptProcessor.store_file(file_params)
      assert String.ends_with?(dest_path, ".pdf")
      assert mime == "application/pdf"

      # Cleanup
      File.rm(dest_path)
      File.rm!(path)
    end

    test "generates unique filenames for same original name" do
      path1 = Path.join(System.tmp_dir!(), "test_upload_1_#{System.unique_integer()}.jpg")
      path2 = Path.join(System.tmp_dir!(), "test_upload_2_#{System.unique_integer()}.jpg")
      File.write!(path1, "data 1")
      File.write!(path2, "data 2")

      file_params1 = %{path: path1, client_name: "receipt.jpg"}
      file_params2 = %{path: path2, client_name: "receipt.jpg"}

      {:ok, dest_path1, _hash, _size, _mime} = ReceiptProcessor.store_file(file_params1)
      {:ok, dest_path2, _hash, _size, _mime} = ReceiptProcessor.store_file(file_params2)

      assert dest_path1 != dest_path2

      # Cleanup
      File.rm(dest_path1)
      File.rm(dest_path2)
      File.rm!(path1)
      File.rm!(path2)
    end
  end

  describe "check_duplicate/2" do
    test "returns :ok when no duplicate exists", %{account: account} do
      hash = "abc123def456"
      assert :ok = ReceiptProcessor.check_duplicate(hash, account.id)
    end

    test "returns error when duplicate exists", %{account: account} do
      # Create a receipt with a known hash
      {:ok, _receipt} =
        Inventory.create_receipt(
          account.id,
          %{
            file_path: "/tmp/test.jpg",
            file_hash: "duplicate_hash_123",
            file_size: 1000,
            mime_type: "image/jpeg"
          },
          authorize?: false,
          tenant: account.id
        )

      # Try to check for duplicate with same hash
      assert {:error, {:duplicate_receipt, _existing}} =
               ReceiptProcessor.check_duplicate("duplicate_hash_123", account.id)
    end

    test "allows same hash for different accounts", %{account: account} do
      # Create another account
      other_account = create_account()

      # Create receipt in first account
      {:ok, _receipt} =
        Inventory.create_receipt(
          account.id,
          %{
            file_path: "/tmp/test.jpg",
            file_hash: "shared_hash",
            file_size: 1000,
            mime_type: "image/jpeg"
          },
          authorize?: false,
          tenant: account.id
        )

      # Same hash should be allowed for different account
      assert :ok = ReceiptProcessor.check_duplicate("shared_hash", other_account.id)
    end

    test "fails closed when the duplicate query itself errors (cxk)", %{account: account} do
      # Force the dedupe query to fail rather than answer: a nil hash violates the
      # find_by_hash action's required argument, so it returns {:error, _} — the
      # same branch a real DB/connectivity failure would hit. check_duplicate must
      # NOT fall through to :ok (fail-open): an unanswerable query blocks the
      # upload so a possible duplicate can't silently double-count inventory/spend.
      assert {:error, {:duplicate_check_failed, _reason}} =
               ReceiptProcessor.check_duplicate(nil, account.id)
    end
  end

  describe "parse_receipt_attrs/1 and parse_item_attrs_list/1" do
    # The sidecar returns the flat ExtractionResponsePayload (python_service/
    # schemas.py). These parsers are pure — the extract/persist workers feed the
    # results into mark_extracted and Ash.bulk_create. Fixtures use ONLY the real
    # wire shape (float amounts; currency/raw_ocr_text/... in the payload).

    test "parses receipt metadata from the flat payload" do
      payload = %{
        "merchant" => "Test Store",
        "date" => "2026-02-01",
        "total" => 25.99,
        "currency" => "USD",
        "raw_ocr_text" => "TEST STORE\nMILK 3.99\nBREAD 2.50",
        "overall_confidence" => 0.87,
        "model_version" => "tesseract-5.3.0",
        "processing_time_ms" => 1500.0
      }

      attrs = ReceiptProcessor.parse_receipt_attrs(payload)

      assert attrs.merchant_name == "Test Store"
      assert attrs.purchase_date == ~D[2026-02-01]
      assert Money.equal?(attrs.total_amount, Money.new("25.99", :USD))
      assert attrs.raw_ocr_text == "TEST STORE\nMILK 3.99\nBREAD 2.50"
      assert attrs.extraction_confidence == 0.87
      assert attrs.model_version == "tesseract-5.3.0"
      assert attrs.processing_time_ms == 1500
      assert attrs.processed_at != nil
    end

    test "parses line items with line_no position and currency-bearing money" do
      payload = %{
        "currency" => "USD",
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
            "confidence" => 0.85
          }
        ]
      }

      [milk, bread] = ReceiptProcessor.parse_item_attrs_list(payload)

      assert milk.line_no == 0
      assert milk.raw_name == "Milk"
      assert milk.final_name == "Milk"
      assert milk.quantity == Decimal.new("1")
      assert milk.unit == "each"
      assert Money.equal?(milk.unit_price, Money.new("3.99", :USD))
      assert Money.equal?(milk.total_price, Money.new("3.99", :USD))
      assert milk.confidence == 0.9

      assert bread.line_no == 1
      assert Money.equal?(bread.total_price, Money.new("2.50", :USD))
    end

    test "currency from the payload drives the amounts (grocery_planner-83o)" do
      payload = %{
        "total" => 4.50,
        "currency" => "GBP",
        "items" => [
          %{
            "name" => "Beans",
            "quantity" => 1,
            "unit" => "tin",
            "price" => 4.50,
            "confidence" => 0.8
          }
        ]
      }

      attrs = ReceiptProcessor.parse_receipt_attrs(payload)
      assert Money.equal?(attrs.total_amount, Money.new("4.50", :GBP))
      assert attrs.total_amount.currency == :GBP

      [beans] = ReceiptProcessor.parse_item_attrs_list(payload)
      assert beans.unit_price.currency == :GBP
    end

    test "nil optional fields parse to nil, not a crash" do
      payload = %{
        "merchant" => nil,
        "date" => nil,
        "total" => nil,
        "currency" => "USD",
        "raw_ocr_text" => "UNREADABLE",
        "overall_confidence" => 0.3,
        "model_version" => "tesseract-5.3.0",
        "processing_time_ms" => 1000.0,
        "items" => []
      }

      attrs = ReceiptProcessor.parse_receipt_attrs(payload)
      assert attrs.merchant_name == nil
      assert attrs.purchase_date == nil
      assert attrs.total_amount == nil
      assert attrs.extraction_confidence == 0.3
      assert ReceiptProcessor.parse_item_attrs_list(payload) == []
    end

    test "invalid date parses to nil" do
      attrs =
        ReceiptProcessor.parse_receipt_attrs(%{"date" => "invalid-date", "currency" => "USD"})

      assert attrs.purchase_date == nil
    end
  end

  describe "contract: flat wire payload <-> parser" do
    # Load-bearing half of the AI-006 contract test. @wire_payload mirrors
    # python_service/schemas.py ExtractionResponsePayload EXACTLY; the Python side
    # pins the same field set. Together they fail loudly if either end drifts.
    @wire_payload %{
      "items" => [
        %{
          "name" => "Bananas",
          "quantity" => 1.0,
          "unit" => "bunch",
          "price" => 1.99,
          "confidence" => 0.98
        }
      ],
      "total" => 1.99,
      "merchant" => "Contract Market",
      "date" => "2026-03-04",
      "currency" => "USD",
      "raw_ocr_text" => "CONTRACT MARKET\nBANANAS 1.99",
      "overall_confidence" => 0.9,
      "model_version" => "tesseract-5.4.0",
      "processing_time_ms" => 1234.5
    }

    test "every field the parser reads is present on the wire payload" do
      attrs = ReceiptProcessor.parse_receipt_attrs(@wire_payload)

      assert attrs.merchant_name == "Contract Market"
      assert attrs.purchase_date == ~D[2026-03-04]
      assert Money.equal?(attrs.total_amount, Money.new("1.99", :USD))
      assert attrs.raw_ocr_text == "CONTRACT MARKET\nBANANAS 1.99"
      assert attrs.extraction_confidence == 0.9
      assert attrs.model_version == "tesseract-5.4.0"
      assert attrs.processing_time_ms == 1235

      [item] = ReceiptProcessor.parse_item_attrs_list(@wire_payload)
      assert item.raw_name == "Bananas"
      assert item.line_no == 0
      assert Money.equal?(item.unit_price, Money.new("1.99", :USD))
    end
  end

  describe "create_inventory_entries/2" do
    test "creates entries for confirmed receipt items", %{account: account, user: user} do
      # Create a grocery item
      item = create_grocery_item(account, user, %{name: "Milk"})

      # Create a receipt
      {:ok, receipt} =
        Inventory.create_receipt(
          account.id,
          %{
            file_path: "/tmp/test.jpg",
            file_hash: "entries123",
            file_size: 1000,
            mime_type: "image/jpeg"
          },
          authorize?: false,
          tenant: account.id
        )

      # Update receipt with purchase_date
      {:ok, receipt} =
        Inventory.update_receipt(
          receipt,
          %{purchase_date: ~D[2026-02-01]},
          authorize?: false,
          tenant: account.id
        )

      # Create a confirmed receipt item
      {:ok, receipt_item} =
        Inventory.create_receipt_item(
          receipt.id,
          account.id,
          %{
            raw_name: "MILK",
            final_name: "Milk",
            quantity: Decimal.new("2"),
            unit: "gallon",
            total_price: Money.new("7.98", :USD),
            confidence: 0.9
          },
          authorize?: false,
          tenant: account.id
        )

      # Link to grocery item and confirm the item
      {:ok, _confirmed_item} =
        Inventory.update_receipt_item(
          receipt_item,
          %{
            status: :confirmed,
            grocery_item_id: item.id,
            final_quantity: Decimal.new("2"),
            final_unit: "gallon"
          },
          authorize?: false,
          tenant: account.id
        )

      # Create storage location
      location = create_storage_location(account, user, %{name: "Fridge"})

      # Create inventory entries
      assert {:ok, results} =
               ReceiptProcessor.create_inventory_entries(receipt,
                 storage_location_id: location.id
               )

      assert length(results) == 1
      {:ok, entry} = List.first(results)
      assert entry.grocery_item_id == item.id
      assert entry.quantity == Decimal.new("2")
      assert entry.unit == "gallon"
      assert entry.purchase_date == ~D[2026-02-01]
      assert entry.purchase_price == Money.new("7.98", :USD)
      assert entry.storage_location_id == location.id
    end

    test "skips pending and skipped items", %{account: account, user: user} do
      item = create_grocery_item(account, user, %{name: "Bread"})

      {:ok, receipt} =
        Inventory.create_receipt(
          account.id,
          %{
            file_path: "/tmp/test.jpg",
            file_hash: "skip123",
            file_size: 1000,
            mime_type: "image/jpeg"
          },
          authorize?: false,
          tenant: account.id
        )

      # Create a pending item
      {:ok, pending_item} =
        Inventory.create_receipt_item(
          receipt.id,
          account.id,
          %{
            raw_name: "BREAD"
          },
          authorize?: false,
          tenant: account.id
        )

      # Link to grocery item but keep as pending
      {:ok, _pending_item} =
        Inventory.update_receipt_item(
          pending_item,
          %{grocery_item_id: item.id},
          authorize?: false,
          tenant: account.id
        )

      # Create inventory entries - should skip pending items
      assert {:ok, results} = ReceiptProcessor.create_inventory_entries(receipt)
      assert results == []
    end

    test "creates entries without storage location", %{account: account, user: user} do
      item = create_grocery_item(account, user, %{name: "Eggs"})

      {:ok, receipt} =
        Inventory.create_receipt(
          account.id,
          %{
            file_path: "/tmp/test.jpg",
            file_hash: "nostorage123",
            file_size: 1000,
            mime_type: "image/jpeg"
          },
          authorize?: false,
          tenant: account.id
        )

      # Update receipt with purchase_date
      {:ok, receipt} =
        Inventory.update_receipt(
          receipt,
          %{purchase_date: ~D[2026-02-01]},
          authorize?: false,
          tenant: account.id
        )

      {:ok, receipt_item} =
        Inventory.create_receipt_item(
          receipt.id,
          account.id,
          %{
            raw_name: "EGGS",
            quantity: Decimal.new("1")
          },
          authorize?: false,
          tenant: account.id
        )

      {:ok, _confirmed} =
        Inventory.update_receipt_item(
          receipt_item,
          %{
            status: :confirmed,
            grocery_item_id: item.id
          },
          authorize?: false,
          tenant: account.id
        )

      # Create without storage location
      assert {:ok, results} = ReceiptProcessor.create_inventory_entries(receipt)
      assert length(results) == 1

      {:ok, entry} = List.first(results)
      assert entry.storage_location_id == nil
    end
  end

  describe "ensure_grocery_item/3" do
    test "returns existing grocery_item_id when already set", %{account: account, user: user} do
      item = create_grocery_item(account, user, %{name: "Existing Item"})

      receipt_item = %{
        grocery_item_id: item.id,
        final_name: "Existing Item",
        raw_name: "EXISTING ITEM",
        final_unit: nil,
        unit: "each",
        id: nil
      }

      expected_id = item.id
      assert {:ok, ^expected_id} = ReceiptProcessor.ensure_grocery_item(receipt_item, account.id)
    end

    test "creates new GroceryItem when grocery_item_id is nil", %{account: account} do
      # Create a receipt and receipt item in DB so the linking update works
      {:ok, receipt} =
        Inventory.create_receipt(
          account.id,
          %{
            file_path: "/tmp/test.jpg",
            file_hash: "ensure_new_#{System.unique_integer()}",
            file_size: 1000,
            mime_type: "image/jpeg"
          },
          authorize?: false,
          tenant: account.id
        )

      {:ok, receipt_item} =
        Inventory.create_receipt_item(
          receipt.id,
          account.id,
          %{
            raw_name: "ORGANIC AVOCADOS",
            final_name: "Organic Avocados",
            quantity: Decimal.new("3"),
            unit: "each"
          },
          authorize?: false,
          tenant: account.id
        )

      assert {:ok, grocery_item_id} =
               ReceiptProcessor.ensure_grocery_item(receipt_item, account.id)

      assert is_binary(grocery_item_id)

      # Verify the GroceryItem was created
      {:ok, grocery_item} =
        Inventory.get_grocery_item(grocery_item_id, authorize?: false, tenant: account.id)

      assert grocery_item.name == "Organic Avocados"
      assert grocery_item.default_unit == "each"
    end

    test "uses raw_name when final_name is nil", %{account: account} do
      {:ok, receipt} =
        Inventory.create_receipt(
          account.id,
          %{
            file_path: "/tmp/test.jpg",
            file_hash: "ensure_raw_#{System.unique_integer()}",
            file_size: 1000,
            mime_type: "image/jpeg"
          },
          authorize?: false,
          tenant: account.id
        )

      {:ok, receipt_item} =
        Inventory.create_receipt_item(
          receipt.id,
          account.id,
          %{raw_name: "FRESH SALMON", quantity: Decimal.new("1"), unit: "lb"},
          authorize?: false,
          tenant: account.id
        )

      assert {:ok, grocery_item_id} =
               ReceiptProcessor.ensure_grocery_item(receipt_item, account.id)

      {:ok, grocery_item} =
        Inventory.get_grocery_item(grocery_item_id, authorize?: false, tenant: account.id)

      assert grocery_item.name == "FRESH SALMON"
    end

    test "creates new GroceryItem even when one with same name exists (no uniqueness constraint)",
         %{account: account, user: user} do
      # Pre-create a grocery item
      _existing = create_grocery_item(account, user, %{name: "Bananas", default_unit: "bunch"})

      {:ok, receipt} =
        Inventory.create_receipt(
          account.id,
          %{
            file_path: "/tmp/test.jpg",
            file_hash: "ensure_dup_#{System.unique_integer()}",
            file_size: 1000,
            mime_type: "image/jpeg"
          },
          authorize?: false,
          tenant: account.id
        )

      {:ok, receipt_item} =
        Inventory.create_receipt_item(
          receipt.id,
          account.id,
          %{raw_name: "BANANAS", final_name: "Bananas", quantity: Decimal.new("6"), unit: "each"},
          authorize?: false,
          tenant: account.id
        )

      # Should create a new GroceryItem (no name uniqueness enforced)
      assert {:ok, grocery_item_id} =
               ReceiptProcessor.ensure_grocery_item(receipt_item, account.id)

      assert is_binary(grocery_item_id)

      {:ok, grocery_item} =
        Inventory.get_grocery_item(grocery_item_id, authorize?: false, tenant: account.id)

      assert grocery_item.name == "Bananas"
    end

    test "links receipt item to newly created GroceryItem", %{account: account} do
      {:ok, receipt} =
        Inventory.create_receipt(
          account.id,
          %{
            file_path: "/tmp/test.jpg",
            file_hash: "ensure_link_#{System.unique_integer()}",
            file_size: 1000,
            mime_type: "image/jpeg"
          },
          authorize?: false,
          tenant: account.id
        )

      {:ok, receipt_item} =
        Inventory.create_receipt_item(
          receipt.id,
          account.id,
          %{
            raw_name: "KALE CHIPS",
            final_name: "Kale Chips",
            quantity: Decimal.new("1"),
            unit: "bag"
          },
          authorize?: false,
          tenant: account.id
        )

      assert is_nil(receipt_item.grocery_item_id)

      {:ok, grocery_item_id} = ReceiptProcessor.ensure_grocery_item(receipt_item, account.id)

      # Verify the receipt item was updated with the grocery_item_id
      {:ok, updated_item} =
        Inventory.get_receipt_item(receipt_item.id, authorize?: false, tenant: account.id)

      assert updated_item.grocery_item_id == grocery_item_id
    end
  end

  describe "create_inventory_entries/2 with unmatched items" do
    test "auto-creates GroceryItems for confirmed items without grocery_item_id", %{
      account: account
    } do
      {:ok, receipt} =
        Inventory.create_receipt(
          account.id,
          %{
            file_path: "/tmp/test.jpg",
            file_hash: "auto_create_#{System.unique_integer()}",
            file_size: 1000,
            mime_type: "image/jpeg"
          },
          authorize?: false,
          tenant: account.id
        )

      {:ok, receipt} =
        Inventory.update_receipt(receipt, %{purchase_date: ~D[2026-02-01]},
          authorize?: false,
          tenant: account.id
        )

      # Create a confirmed receipt item WITHOUT grocery_item_id
      {:ok, receipt_item} =
        Inventory.create_receipt_item(
          receipt.id,
          account.id,
          %{
            raw_name: "DRAGON FRUIT",
            final_name: "Dragon Fruit",
            quantity: Decimal.new("2"),
            unit: "each"
          },
          authorize?: false,
          tenant: account.id
        )

      {:ok, _} =
        Inventory.update_receipt_item(
          receipt_item,
          %{status: :confirmed, final_quantity: Decimal.new("2"), final_unit: "each"},
          authorize?: false,
          tenant: account.id
        )

      # Should succeed - auto-creating the GroceryItem
      assert {:ok, results} = ReceiptProcessor.create_inventory_entries(receipt)
      assert length(results) == 1
      assert {:ok, entry} = List.first(results)
      assert entry.quantity == Decimal.new("2")

      # Verify the GroceryItem was created
      {:ok, grocery_item} =
        Inventory.get_grocery_item(entry.grocery_item_id, authorize?: false, tenant: account.id)

      assert grocery_item.name == "Dragon Fruit"
    end
  end
end
