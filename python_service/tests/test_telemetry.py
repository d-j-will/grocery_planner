"""
Tests for OpenTelemetry instrumentation setup.

Covers:
- Telemetry module initialization
- OTEL configuration settings
- Trace context in structured logs
- Graceful degradation when OTEL is disabled
"""

import json
import logging
import os
import importlib
from unittest.mock import MagicMock, patch


class TestOtelConfiguration:
    """Test OTEL configuration settings."""

    def test_otel_disabled_by_default(self):
        """OTEL should be off unless explicitly enabled."""
        # Default is "false"
        with patch.dict(os.environ, {}, clear=False):
            os.environ.pop("OTEL_ENABLED", None)
            # Reload the module to pick up env changes
            import config
            importlib.reload(config)
            assert config.settings.OTEL_ENABLED is False

    def test_otel_enabled_via_env(self):
        """OTEL_ENABLED=true should enable telemetry."""
        with patch.dict(os.environ, {"OTEL_ENABLED": "true"}, clear=False):
            import config
            importlib.reload(config)
            assert config.settings.OTEL_ENABLED is True
        # Restore
        import config
        importlib.reload(config)

    def test_default_otlp_endpoint(self):
        """Default OTLP endpoint is localhost:4317."""
        from config import settings
        assert "localhost:4317" in settings.OTEL_EXPORTER_OTLP_ENDPOINT

    def test_custom_otlp_endpoint_via_env(self):
        """OTLP endpoint can be overridden via env."""
        with patch.dict(os.environ, {"OTEL_EXPORTER_OTLP_ENDPOINT": "http://tempo:4317"}, clear=False):
            import config
            importlib.reload(config)
            assert config.settings.OTEL_EXPORTER_OTLP_ENDPOINT == "http://tempo:4317"
        import config
        importlib.reload(config)

    def test_default_service_name(self):
        """Default service name is grocery-planner-ai."""
        from config import settings
        assert settings.OTEL_SERVICE_NAME == "grocery-planner-ai"

    def test_custom_service_name_via_env(self):
        """Service name can be overridden via env."""
        with patch.dict(os.environ, {"OTEL_SERVICE_NAME": "my-ai-service"}, clear=False):
            import config
            importlib.reload(config)
            assert config.settings.OTEL_SERVICE_NAME == "my-ai-service"
        import config
        importlib.reload(config)


class TestTelemetryModule:
    """Test the telemetry setup module."""

    def test_setup_telemetry_creates_provider(self):
        """setup_telemetry should return a TracerProvider."""
        from telemetry import setup_telemetry
        from opentelemetry.sdk.trace import TracerProvider

        mock_app = MagicMock()
        provider = setup_telemetry(
            mock_app,
            endpoint="http://localhost:4317",
            service_name="test-service",
        )
        assert isinstance(provider, TracerProvider)

    def test_setup_telemetry_instruments_fastapi(self):
        """setup_telemetry should instrument the FastAPI app."""
        from telemetry import setup_telemetry
        from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor

        mock_app = MagicMock()

        with patch.object(FastAPIInstrumentor, "instrument_app") as mock_instrument:
            setup_telemetry(mock_app, service_name="test-svc")
            mock_instrument.assert_called_once_with(mock_app)

    def test_setup_telemetry_instruments_logging(self):
        """setup_telemetry should add trace context to logging."""
        from telemetry import setup_telemetry
        from opentelemetry.instrumentation.logging import LoggingInstrumentor

        mock_app = MagicMock()

        with patch.object(LoggingInstrumentor, "instrument") as mock_instrument:
            setup_telemetry(mock_app, service_name="test-svc")
            mock_instrument.assert_called_once_with(set_logging_format=True)

    def test_tracer_is_available(self):
        """Module-level tracer should be importable."""
        from telemetry import tracer
        assert tracer is not None


class TestTraceContextInLogs:
    """Test that OTEL trace context appears in structured logs."""

    def test_structured_logger_includes_trace_fields_when_span_active(self):
        """StructuredLogger should include trace_id/span_id when a span is active."""
        from middleware import StructuredLogger
        from opentelemetry import trace
        from opentelemetry.sdk.trace import TracerProvider

        provider = TracerProvider()
        trace.set_tracer_provider(provider)
        tracer = trace.get_tracer("test")

        formatter = StructuredLogger()

        with tracer.start_as_current_span("test-span"):
            record = logging.LogRecord(
                name="test",
                level=logging.INFO,
                pathname="",
                lineno=0,
                msg="test message",
                args=None,
                exc_info=None,
            )
            output = formatter.format(record)
            data = json.loads(output)

            assert "trace_id" in data
            assert "span_id" in data
            assert len(data["trace_id"]) == 32
            assert len(data["span_id"]) == 16

    def test_structured_logger_omits_trace_fields_when_no_span(self):
        """StructuredLogger should not include trace fields when no span is active."""
        from middleware import StructuredLogger
        from opentelemetry import trace
        from opentelemetry.sdk.trace import TracerProvider

        provider = TracerProvider()
        trace.set_tracer_provider(provider)

        formatter = StructuredLogger()
        record = logging.LogRecord(
            name="test",
            level=logging.INFO,
            pathname="",
            lineno=0,
            msg="test message",
            args=None,
            exc_info=None,
        )
        output = formatter.format(record)
        data = json.loads(output)

        assert "trace_id" not in data
        assert "span_id" not in data


class TestMainAppOtelIntegration:
    """Test that OTEL initialization in main.py works correctly."""

    def test_telemetry_module_is_importable(self):
        """The telemetry module should be importable and have required functions."""
        telemetry_module = importlib.import_module("telemetry")
        assert hasattr(telemetry_module, "setup_telemetry")
        assert hasattr(telemetry_module, "tracer")
        assert callable(telemetry_module.setup_telemetry)

    def test_telemetry_tracer_can_create_spans(self):
        """The module-level tracer should be able to create spans."""
        from telemetry import tracer
        from opentelemetry import trace
        from opentelemetry.sdk.trace import TracerProvider

        provider = TracerProvider()
        trace.set_tracer_provider(provider)

        with tracer.start_as_current_span("test-operation") as span:
            assert span is not None
            span.set_attribute("test.key", "test-value")
