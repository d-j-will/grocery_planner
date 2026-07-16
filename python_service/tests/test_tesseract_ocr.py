"""
Tests for Tesseract OCR fallback path.

Tests cover:
- Tesseract OCR endpoint with base64 image
- Direct process_receipt() function
- Configuration flag validation
"""

import os
import pytest
import base64
from unittest.mock import patch
from fastapi.testclient import TestClient
import tempfile

from main import app
from database import Base, get_engine, reset_engine
from config import settings

# Create a temporary database file for tests
_test_db_file = tempfile.NamedTemporaryFile(suffix=".db", delete=False)
os.environ["AI_DATABASE_URL"] = f"sqlite:///{_test_db_file.name}"


@pytest.fixture(scope="function")
def db_session():
    """Create a fresh database for each test."""
    reset_engine()
    engine = get_engine()
    Base.metadata.drop_all(bind=engine)
    Base.metadata.create_all(bind=engine)
    yield
    Base.metadata.drop_all(bind=engine)


@pytest.fixture
def client(db_session):
    """Create test client with fresh database."""
    return TestClient(app)


@pytest.fixture
def sample_receipt_base64():
    """Load the sample receipt image as base64."""
    fixture_path = os.path.join(
        os.path.dirname(__file__), "fixtures", "sample_receipt.png"
    )
    with open(fixture_path, "rb") as f:
        return base64.b64encode(f.read()).decode()


class TestTesseractExtractReceiptEndpoint:
    """Tests for /api/v1/extract-receipt endpoint with Tesseract OCR."""

    @patch('main.settings.USE_TESSERACT_OCR', True)
    @patch('main.settings.USE_VLLM_OCR', False)
    def test_tesseract_extract_receipt_endpoint(self, client, sample_receipt_base64):
        """Test the extract-receipt endpoint with Tesseract OCR enabled."""
        response = client.post("/api/v1/extract-receipt", json={
            "request_id": "test-tesseract-123",
            "tenant_id": "test-tenant",
            "user_id": "test-user",
            "feature": "extraction",
            "payload": {
                "image_base64": sample_receipt_base64
            }
        })

        assert response.status_code == 200
        data = response.json()

        # Check response envelope
        assert data["request_id"] == "test-tesseract-123"
        assert data["status"] == "success"
        assert "payload" in data

        # Check payload structure
        payload = data["payload"]
        assert "items" in payload

        # Items should be a list (may be empty if OCR couldn't extract anything)
        assert isinstance(payload["items"], list)

        # If items were extracted, validate their structure
        if len(payload["items"]) > 0:
            item = payload["items"][0]
            assert "name" in item
            assert "quantity" in item
            assert "price" in item
            assert "confidence" in item

        # Check optional fields exist (may be null)
        assert "total" in payload
        assert "merchant" in payload
        assert "date" in payload

        # Enriched flat contract (AI-006 §5): the Tesseract branch must stop
        # discarding these — they were computed and thrown away before.
        assert isinstance(payload["currency"], str) and payload["currency"]
        assert isinstance(payload["raw_ocr_text"], str)
        assert 0.0 <= payload["overall_confidence"] <= 1.0
        assert "tesseract" in payload["model_version"].lower()
        assert payload["processing_time_ms"] >= 0

    @patch('main.settings.USE_TESSERACT_OCR', True)
    @patch('main.settings.USE_VLLM_OCR', False)
    def test_tesseract_endpoint_invalid_base64(self, client):
        """Test endpoint with invalid base64 data."""
        response = client.post("/api/v1/extract-receipt", json={
            "request_id": "test-invalid-b64",
            "tenant_id": "test-tenant",
            "user_id": "test-user",
            "feature": "extraction",
            "payload": {
                "image_base64": "not-valid-base64!!!"
            }
        })

        # Should return 200 with error status (error handling in endpoint)
        assert response.status_code in [200, 500]
        if response.status_code == 200:
            data = response.json()
            assert data["status"] in ["error", "failure"]

    @patch('main.settings.USE_TESSERACT_OCR', True)
    @patch('main.settings.USE_VLLM_OCR', False)
    @patch('main._tesseract_process_receipt', None)
    def test_tesseract_not_installed_returns_error(self, client, sample_receipt_base64):
        """Test that missing Tesseract returns error status."""
        response = client.post("/api/v1/extract-receipt", json={
            "request_id": "test-no-tesseract",
            "tenant_id": "test-tenant",
            "user_id": "test-user",
            "feature": "extraction",
            "payload": {
                "image_base64": sample_receipt_base64
            }
        })

        assert response.status_code == 200
        data = response.json()
        assert data["status"] == "error"
        assert "tesseract" in data["error"].lower() or "503" in data["error"]

    @patch('main.settings.USE_TESSERACT_OCR', True)
    @patch('main.settings.USE_VLLM_OCR', False)
    def test_tesseract_endpoint_creates_artifact(self, client, sample_receipt_base64):
        """Test that successful extraction creates an artifact."""
        response = client.post("/api/v1/extract-receipt", json={
            "request_id": "test-artifact-creation",
            "tenant_id": "test-tenant-artifact",
            "user_id": "test-user",
            "feature": "extraction",
            "payload": {
                "image_base64": sample_receipt_base64
            }
        })

        assert response.status_code == 200

        # Check that an artifact was created
        artifacts_response = client.get(
            "/api/v1/artifacts",
            params={"tenant_id": "test-tenant-artifact"},
            headers={"X-Tenant-ID": "test-tenant-artifact"}
        )

        assert artifacts_response.status_code == 200
        artifacts = artifacts_response.json()["artifacts"]
        assert len(artifacts) >= 1

        # Find our artifact
        artifact = next(
            (a for a in artifacts if a["request_id"] == "test-artifact-creation"),
            None
        )
        assert artifact is not None
        assert artifact["feature"] == "receipt_extraction"


class TestTesseractProcessReceipt:
    """Tests for receipt_ocr.process_receipt() function directly."""

    @patch('main.settings.USE_TESSERACT_OCR', True)
    def test_process_receipt_returns_extraction_result(self):
        """Test that process_receipt returns an ExtractionResult with line_items."""
        from receipt_ocr import process_receipt
        from schemas import ExtractionResult

        fixture_path = os.path.join(
            os.path.dirname(__file__), "fixtures", "sample_receipt.png"
        )

        result = process_receipt(fixture_path)

        # Should return an ExtractionResult
        assert isinstance(result, ExtractionResult)

        # Should have line_items (may be empty if OCR fails)
        assert hasattr(result, 'line_items')
        assert isinstance(result.line_items, list)

        # Should have merchant, date, total fields
        assert hasattr(result, 'merchant')
        assert hasattr(result, 'date')
        assert hasattr(result, 'total')
        assert hasattr(result, 'overall_confidence')

    @patch('main.settings.USE_TESSERACT_OCR', True)
    def test_process_receipt_with_real_tesseract(self):
        """Integration test with real Tesseract OCR on sample receipt."""
        from receipt_ocr import process_receipt

        fixture_path = os.path.join(
            os.path.dirname(__file__), "fixtures", "sample_receipt.png"
        )

        result = process_receipt(fixture_path)

        # With real Tesseract, we should get some extraction
        # (even if not perfect, should at least attempt parsing)
        assert result.overall_confidence >= 0.0

        # If we got items, validate their structure
        for item in result.line_items:
            assert hasattr(item, 'raw_text')
            assert hasattr(item, 'parsed_name')
            assert hasattr(item, 'quantity')
            assert hasattr(item, 'confidence')

    def test_process_receipt_file_not_found(self):
        """Test that process_receipt raises FileNotFoundError for missing files."""
        from receipt_ocr import process_receipt

        with pytest.raises(FileNotFoundError):
            process_receipt("/nonexistent/path/receipt.png")


class TestTesseractConfig:
    """Tests for Tesseract configuration flags."""

    def test_tesseract_config_flag_exists(self):
        """Test that USE_TESSERACT_OCR config flag exists."""

        assert hasattr(settings, 'USE_TESSERACT_OCR')
        assert isinstance(settings.USE_TESSERACT_OCR, bool)

    def test_tesseract_config_default_true(self):
        """Test that USE_TESSERACT_OCR defaults to True."""
        # Create a new Settings instance without env override
        import importlib
        import config

        # Save original env
        original_env = os.environ.get('USE_TESSERACT_OCR')

        try:
            # Remove env var if it exists
            if 'USE_TESSERACT_OCR' in os.environ:
                del os.environ['USE_TESSERACT_OCR']

            # Reload config to get fresh Settings
            importlib.reload(config)

            assert config.settings.USE_TESSERACT_OCR is True

        finally:
            # Restore original env
            if original_env is not None:
                os.environ['USE_TESSERACT_OCR'] = original_env
            # Reload config again to restore original state
            importlib.reload(config)

    def test_tesseract_config_can_be_disabled(self):
        """Test that USE_TESSERACT_OCR can be set to False via env var."""
        import importlib
        import config

        # Save original env
        original_env = os.environ.get('USE_TESSERACT_OCR')

        try:
            # Set to false
            os.environ['USE_TESSERACT_OCR'] = 'false'

            # Reload config
            importlib.reload(config)

            assert config.settings.USE_TESSERACT_OCR is False

        finally:
            # Restore original env
            if original_env is not None:
                os.environ['USE_TESSERACT_OCR'] = original_env
            else:
                if 'USE_TESSERACT_OCR' in os.environ:
                    del os.environ['USE_TESSERACT_OCR']
            # Reload config to restore
            importlib.reload(config)

    def test_vllm_ocr_config_exists(self):
        """Test that USE_VLLM_OCR config flag exists."""

        assert hasattr(settings, 'USE_VLLM_OCR')
        assert isinstance(settings.USE_VLLM_OCR, bool)
