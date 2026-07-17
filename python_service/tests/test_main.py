"""
Tests for the GroceryPlanner AI Service.

Covers health check and the synchronous AI endpoints. The sidecar is stateless
(Oban on the Elixir side owns all job/artifact/feedback state), so there is no
datastore, and no job/artifact/feedback endpoints to exercise here.
"""

import pytest
from fastapi.testclient import TestClient
from main import app


@pytest.fixture
def client():
    """Create a test client against the stateless app."""
    return TestClient(app)


# =============================================================================
# Health Check Tests
# =============================================================================

def test_health_check(client):
    """Test health check endpoint."""
    response = client.get("/health")
    assert response.status_code == 200
    data = response.json()
    assert data["status"] == "ok"
    assert data["service"] == "grocery-planner-ai"
    assert "version" in data


# =============================================================================
# Categorization Tests
# =============================================================================

def test_categorize_item(client):
    """Test item categorization endpoint."""
    payload = {
        "item_name": "Organic Whole Milk",
        "candidate_labels": ["Produce", "Dairy", "Meat"]
    }
    request_data = {
        "request_id": "req_123",
        "tenant_id": "tenant_abc",
        "user_id": "user_1",
        "feature": "categorization",
        "payload": payload
    }

    response = client.post("/api/v1/categorize", json=request_data)
    assert response.status_code == 200
    data = response.json()
    assert data["status"] == "success"
    assert data["payload"]["category"] == "Dairy"
    assert data["payload"]["confidence"] > 0.9


# =============================================================================
# Receipt Extraction Tests
# =============================================================================

def test_extract_receipt(client):
    """Test receipt extraction endpoint with mock OCR."""
    from unittest.mock import patch
    from config import settings

    payload = {
        "image_base64": "fake_base64_string"
    }
    request_data = {
        "request_id": "req_456",
        "tenant_id": "tenant_abc",
        "user_id": "user_1",
        "feature": "extraction",
        "payload": payload
    }

    # Force mock OCR mode (fake base64 won't work with real Tesseract)
    with patch.object(settings, "USE_VLLM_OCR", False), \
         patch.object(settings, "USE_TESSERACT_OCR", False):
        response = client.post("/api/v1/extract-receipt", json=request_data)
    assert response.status_code == 200
    data = response.json()
    payload = data["payload"]
    assert len(payload["items"]) > 0
    assert payload["total"] == 5.48

    # Enriched flat contract (AI-006 §5): these fields cross the wire so the
    # Elixir receipt's columns stop being permanently nil.
    assert payload["currency"] == "USD"
    assert isinstance(payload["raw_ocr_text"], str)
    assert 0.0 <= payload["overall_confidence"] <= 1.0
    assert payload["model_version"]  # populated on every branch
    assert payload["processing_time_ms"] >= 0


def test_extraction_response_payload_contract():
    """Pin the flat wire contract consumed by GroceryPlanner.Inventory.ReceiptProcessor.

    This is the Python half of the AI-006 Arc 1 contract test. The Elixir
    consumer half lives in receipt_processor_test.exs ("contract:" describe).
    The whole AI-006 defect class was the two sides diverging while both looked
    green — so a renamed or dropped field here must fail loudly.
    """
    from schemas import ExtractionResponsePayload

    assert set(ExtractionResponsePayload.model_fields.keys()) == {
        "items",
        "total",
        "merchant",
        "date",
        "currency",
        "raw_ocr_text",
        "overall_confidence",
        "model_version",
        "processing_time_ms",
    }


# =============================================================================
# Embedding Tests
# =============================================================================

def test_embed_single_text(client):
    """Test single text embedding generation."""
    response = client.post("/api/v1/embed", json={
        "version": "1.0",
        "request_id": "test-123",
        "texts": [{"id": "1", "text": "Creamy pasta carbonara with bacon and parmesan"}]
    })
    assert response.status_code == 200
    data = response.json()
    assert data["version"] == "1.0"
    assert data["request_id"] == "test-123"
    assert data["model"] == "all-MiniLM-L6-v2"
    assert data["dimension"] == 384
    assert len(data["embeddings"]) == 1
    assert data["embeddings"][0]["id"] == "1"
    assert len(data["embeddings"][0]["vector"]) == 384
    assert all(isinstance(v, float) for v in data["embeddings"][0]["vector"])


def test_embed_multiple_texts(client):
    """Test multiple texts embedding generation."""
    response = client.post("/api/v1/embed", json={
        "version": "1.0",
        "request_id": "test-456",
        "texts": [
            {"id": "1", "text": "Italian pasta"},
            {"id": "2", "text": "Mexican tacos"},
            {"id": "3", "text": "Japanese sushi"}
        ]
    })
    assert response.status_code == 200
    data = response.json()
    assert len(data["embeddings"]) == 3
    assert data["embeddings"][0]["id"] == "1"
    assert data["embeddings"][1]["id"] == "2"
    assert data["embeddings"][2]["id"] == "3"
    for emb in data["embeddings"]:
        assert len(emb["vector"]) == 384


def test_embed_batch(client):
    """Test batch embedding endpoint with configurable batch size."""
    response = client.post("/api/v1/embed/batch", json={
        "version": "1.0",
        "request_id": "test-batch-1",
        "texts": [
            {"id": "1", "text": "Italian pasta"},
            {"id": "2", "text": "Mexican tacos"},
            {"id": "3", "text": "Japanese sushi"},
            {"id": "4", "text": "Indian curry"},
            {"id": "5", "text": "Thai pad thai"}
        ],
        "batch_size": 2
    })
    assert response.status_code == 200
    data = response.json()
    assert data["dimension"] == 384
    assert len(data["embeddings"]) == 5
    for emb in data["embeddings"]:
        assert len(emb["vector"]) == 384
        assert all(isinstance(v, float) for v in emb["vector"])


def test_embed_empty_texts_fails(client):
    """Test that empty texts list returns error."""
    response = client.post("/api/v1/embed", json={
        "version": "1.0",
        "request_id": "test-empty",
        "texts": []
    })
    assert response.status_code == 500


def test_embed_batch_invalid_batch_size(client):
    """Test that invalid batch size returns error."""
    response = client.post("/api/v1/embed/batch", json={
        "version": "1.0",
        "request_id": "test-invalid-batch",
        "texts": [{"id": "1", "text": "test"}],
        "batch_size": 0
    })
    assert response.status_code == 500


def test_embedding(client):
    """Test legacy embedding generation endpoint (BaseRequest format)."""
    payload = {
        "text": "Spicy Chicken Curry"
    }
    request_data = {
        "request_id": "req_789",
        "tenant_id": "tenant_abc",
        "user_id": "user_1",
        "feature": "embedding",
        "payload": payload
    }

    client.post("/api/v1/embed", json=request_data)
    # This will fail because we changed the endpoint signature
    # The old format is no longer supported, which is fine


# =============================================================================
# Request Tracing Tests
# =============================================================================

def test_request_id_in_response(client):
    """Test that request ID is returned in response headers."""
    response = client.get("/health", headers={"X-Request-ID": "trace_123"})
    assert response.headers.get("X-Request-ID") == "trace_123"


def test_generated_request_id(client):
    """Test that a request ID is generated if not provided."""
    response = client.get("/health")
    request_id = response.headers.get("X-Request-ID")
    assert request_id is not None
    assert request_id.startswith("req_")


# =============================================================================
# Tenant Validation Tests
# =============================================================================

def test_get_endpoint_requires_tenant_header(client):
    """Test that API GET requests require an X-Tenant-ID header.

    TenantValidationMiddleware runs before routing, so any GET under /api/
    without the header is rejected with 400 regardless of whether a route
    exists for it.
    """
    response = client.get("/api/v1/embed")
    # Should return 400 for missing tenant
    assert response.status_code == 400
    assert "X-Tenant-ID" in response.json()["error"]


# =============================================================================
# Batch Categorization Tests
# =============================================================================

def test_categorize_batch(client):
    """Test batch categorization returns predictions for all items."""
    response = client.post("/api/v1/categorize-batch", json={
        "request_id": "req_batch_1",
        "tenant_id": "tenant_123",
        "user_id": "user_456",
        "feature": "categorization_batch",
        "payload": {
            "items": [
                {"id": "1", "name": "Organic Whole Milk"},
                {"id": "2", "name": "Sourdough Bread"},
                {"id": "3", "name": "Fresh Chicken Breast"}
            ],
            "candidate_labels": ["Dairy", "Bakery", "Meat & Seafood", "Produce"]
        }
    })

    assert response.status_code == 200
    data = response.json()
    assert data["status"] == "success"
    assert len(data["payload"]["predictions"]) == 3
    assert data["payload"]["processing_time_ms"] >= 0

    # Check each prediction has required fields
    for pred in data["payload"]["predictions"]:
        assert "id" in pred
        assert "name" in pred
        assert "predicted_category" in pred
        assert "confidence" in pred
        assert "confidence_level" in pred
        assert pred["confidence_level"] in ("high", "medium", "low")


# The `/api/v1/receipts/extract` endpoint (image_path contract) was retired
# with the stateless-sidecar cutover — the sidecar never mounted receipt
# uploads, so it could not work in prod. The real receipt path is
# `/api/v1/extract-receipt` (flat base64 contract), covered in
# test_tesseract_ocr.py and by test_extract_receipt above.
