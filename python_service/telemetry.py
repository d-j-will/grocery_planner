"""
OpenTelemetry instrumentation setup for the AI service.

Provides distributed tracing with:
- FastAPI auto-instrumentation (HTTP spans)
- Logging integration (trace context in logs)
- Custom span creation for AI operations
"""

import logging

from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.resources import Resource
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.instrumentation.logging import LoggingInstrumentor

logger = logging.getLogger("grocery-planner-ai")

# Module-level tracer for use by endpoints
tracer = trace.get_tracer("grocery-planner-ai")


def setup_telemetry(
    app,
    endpoint="http://localhost:4317",
    service_name="grocery-planner-ai",
):
    """
    Initialize OpenTelemetry with OTLP gRPC exporter.

    Args:
        app: FastAPI application instance
        endpoint: OTLP collector endpoint
        service_name: Service name for trace identification

    Returns:
        TracerProvider instance
    """
    resource = Resource.create(
        {
            "service.name": service_name,
            "service.version": "1.0.0",
        }
    )

    provider = TracerProvider(resource=resource)
    exporter = OTLPSpanExporter(endpoint=endpoint, insecure=True)
    processor = BatchSpanProcessor(exporter)
    provider.add_span_processor(processor)
    trace.set_tracer_provider(provider)

    # Auto-instrument FastAPI (adds HTTP spans)
    FastAPIInstrumentor.instrument_app(app)

    # Add trace context (trace_id, span_id) to log records
    LoggingInstrumentor().instrument(set_logging_format=True)

    logger.info(
        "OpenTelemetry initialized: endpoint=%s, service=%s",
        endpoint,
        service_name,
    )

    return provider
