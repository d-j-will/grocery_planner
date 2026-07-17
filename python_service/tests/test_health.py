"""
Tests for health check endpoints (/health, /health/ready, /health/live).

Covers basic health, readiness with dependency checks, and liveness probe.
"""

import pytest
from fastapi.testclient import TestClient
from main import app


@pytest.fixture
def client():
    """Create a test client against the stateless app."""
    return TestClient(app)


# =============================================================================
# /health - Basic Health Check
# =============================================================================


def test_health_returns_ok(client):
    """Basic health check returns 200 with service info."""
    response = client.get("/health")
    assert response.status_code == 200
    data = response.json()
    assert data["status"] == "ok"
    assert data["service"] == "grocery-planner-ai"
    assert data["version"] == "1.0.0"


# =============================================================================
# /health/ready - Readiness Check
# =============================================================================


def test_readiness_check_returns_dependency_statuses(client):
    """Readiness check reports status for all dependencies."""
    response = client.get("/health/ready")
    assert response.status_code == 200
    data = response.json()

    assert "status" in data
    assert "checks" in data
    assert "version" in data

    checks = data["checks"]
    # The sidecar is stateless — there is no datastore to probe. Readiness is
    # only about the model/OCR dependencies this service actually uses.
    assert "database" not in checks
    assert "classifier" in checks
    assert "embedding_model" in checks
    assert "tesseract" in checks


def test_readiness_classifier_not_loaded_in_test(client):
    """Classifier shows not_loaded when USE_REAL_CLASSIFICATION is false."""
    response = client.get("/health/ready")
    data = response.json()
    # In test mode, classifier is not loaded
    assert data["checks"]["classifier"]["status"] == "not_loaded"
    assert data["checks"]["classifier"]["model"] is None


def test_readiness_overall_status_ok_when_deps_healthy(client):
    """Overall status is 'ok' when all dependencies are healthy or optional."""
    response = client.get("/health/ready")
    data = response.json()
    # not_loaded and not_installed are acceptable non-error states
    assert data["status"] in ("ok", "degraded")


def test_readiness_includes_version(client):
    """Readiness response includes service version."""
    response = client.get("/health/ready")
    data = response.json()
    assert data["version"] == "1.0.0"


# =============================================================================
# /health/live - Liveness Probe
# =============================================================================


def test_liveness_check_returns_ok(client):
    """Liveness probe returns minimal 200 OK."""
    response = client.get("/health/live")
    assert response.status_code == 200
    data = response.json()
    assert data["status"] == "ok"


def test_liveness_check_is_fast(client):
    """Liveness probe completes quickly (no dependency checks)."""
    import time

    start = time.time()
    response = client.get("/health/live")
    elapsed_ms = (time.time() - start) * 1000

    assert response.status_code == 200
    # Liveness should be very fast since it does no I/O
    assert elapsed_ms < 500
