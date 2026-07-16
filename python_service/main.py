"""
GroceryPlanner AI Service

FastAPI application providing AI capabilities for the GroceryPlanner application.
Features include categorization, receipt extraction, embeddings, and more.
"""

import time
import os
from contextlib import asynccontextmanager
from typing import Optional

from fastapi import FastAPI, Depends, HTTPException, Query
from sqlalchemy.orm import Session

from schemas import (
    BaseRequest, BaseResponse,
    CategorizationRequestPayload, CategorizationResponsePayload,
    BatchCategorizationRequestPayload, BatchCategorizationResponsePayload,
    BatchPrediction, ExtractionRequestPayload, ExtractionResponsePayload, ExtractedItem,
    EmbedRequest, EmbedResponse, EmbedBatchRequest, EmbeddingResult,
    JobSubmitRequest, JobStatusResponse, JobListResponse,
    ArtifactResponse, ArtifactListResponse,
    FeedbackRequest, FeedbackResponse,
    ReceiptExtractRequest, ReceiptExtractResponse,
    MealOptimizationRequestPayload,
    QuickSuggestionRequestPayload,
)
from database import init_db, get_db, JobStatus
from jobs import submit_job, get_job, list_jobs, job_to_dict, register_job_handler
from artifacts import (
    create_artifact, get_artifact, list_artifacts, artifact_to_dict,
    add_feedback, feedback_to_dict
)
from middleware import (
    setup_structured_logging,
    RequestTracingMiddleware,
    TenantValidationMiddleware,
)
from config import settings
import logging

# Optional Tesseract OCR import (graceful fallback if not installed)
try:
    from receipt_ocr import process_receipt as _tesseract_process_receipt
except ImportError:
    _tesseract_process_receipt = None

# Optional meal optimizer import (graceful fallback if not installed)
try:
    from meal_optimizer import optimize_meal_plan, quick_suggestions
except ImportError:
    optimize_meal_plan = None
    quick_suggestions = None

# Setup structured logging
setup_structured_logging()
logger = logging.getLogger("grocery-planner-ai")

# Global classifier instance (initialized on startup if enabled)
classifier = None

# Global embedding model instance (lazy-loaded on first use)
_embedding_model = None


def get_embedding_model():
    """Lazy-load the sentence transformer model for embeddings."""
    global _embedding_model
    if _embedding_model is None:
        model_name = os.environ.get("EMBEDDING_MODEL", "sentence-transformers/all-MiniLM-L6-v2")
        logger.info(f"Loading embedding model: {model_name}...")
        try:
            from sentence_transformers import SentenceTransformer
            _embedding_model = SentenceTransformer(model_name)
            logger.info("Embedding model loaded successfully")
        except Exception as e:
            logger.error(f"Failed to load embedding model: {e}")
            raise
    return _embedding_model


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Application lifespan manager."""
    global classifier

    # Initialize database
    logger.info("Initializing database...")
    init_db()

    # Initialize OpenTelemetry if enabled
    if settings.OTEL_ENABLED:
        try:
            from telemetry import setup_telemetry
            from database import get_engine
            setup_telemetry(
                app,
                engine=get_engine(),
                endpoint=settings.OTEL_EXPORTER_OTLP_ENDPOINT,
                service_name=settings.OTEL_SERVICE_NAME,
            )
            logger.info("OpenTelemetry initialized")
        except ImportError:
            logger.warning("OpenTelemetry packages not installed, skipping")
        except Exception as e:
            logger.warning(f"Failed to initialize OpenTelemetry: {e}")

    # Load Zero-Shot Classification model if enabled
    if settings.USE_REAL_CLASSIFICATION:
        logger.info(f"Loading classification model: {settings.CLASSIFICATION_MODEL}...")
        try:
            from transformers import pipeline
            classifier = pipeline(
                "zero-shot-classification",
                model=settings.CLASSIFICATION_MODEL,
                device=-1  # CPU
            )
            logger.info("Classification model loaded successfully")
        except Exception as e:
            logger.error(f"Failed to load classification model: {e}")
            classifier = None
    else:
        logger.info("Real classification disabled, using mock implementation")

    logger.info("AI Service starting up...")

    yield

    # Cleanup
    classifier = None
    logger.info("AI Service shutting down...")


app = FastAPI(
    title="GroceryPlanner AI Service",
    description="AI capabilities for the GroceryPlanner application",
    version="1.0.0",
    lifespan=lifespan,
)

# Initialize Tidewave AI-assisted debugging in debug mode
if settings.DEBUG and settings.TIDEWAVE_ENABLED:
    try:
        from tidewave import install as tidewave_install
        from database import get_engine as _get_engine
        tidewave_install(app, sqlalchemy_engine=_get_engine())
        logger.info("Tidewave debugging enabled")
    except ImportError:
        logger.debug("Tidewave not installed, skipping AI-assisted debugging")
    except Exception as e:
        logger.warning(f"Failed to initialize Tidewave: {e}")

# Add middleware (order matters - first added is outermost)
app.add_middleware(TenantValidationMiddleware)
app.add_middleware(RequestTracingMiddleware)


# =============================================================================
# Health Check
# =============================================================================

@app.get("/health")
def health_check():
    """Basic health check for load balancers."""
    return {"status": "ok", "service": "grocery-planner-ai", "version": "1.0.0"}


@app.get("/health/ready")
def readiness_check(db: Session = Depends(get_db)):
    """Full readiness check with dependency validation."""
    checks = {}

    # Database connectivity
    try:
        from sqlalchemy import text
        db.execute(text("SELECT 1"))
        checks["database"] = {"status": "ok"}
    except Exception as e:
        checks["database"] = {"status": "error", "error": str(e)}

    # Classification model loaded
    checks["classifier"] = {
        "status": "ok" if classifier is not None else "not_loaded",
        "model": settings.CLASSIFICATION_MODEL if classifier else None,
    }

    # Embedding model (lazy-loaded, check if importable)
    try:
        from sentence_transformers import SentenceTransformer  # noqa: F401
        checks["embedding_model"] = {"status": "available"}
    except ImportError:
        checks["embedding_model"] = {"status": "not_installed"}

    # Tesseract OCR availability
    checks["tesseract"] = {
        "status": "available" if _tesseract_process_receipt is not None else "not_installed",
    }

    overall = "ok" if all(
        c.get("status") in ("ok", "available", "not_loaded")
        for c in checks.values()
    ) else "degraded"

    return {
        "status": overall,
        "checks": checks,
        "version": "1.0.0",
    }


@app.get("/health/live")
def liveness_check():
    """Simple liveness probe."""
    return {"status": "ok"}


# =============================================================================
# Synchronous AI Endpoints (with artifact storage)
# =============================================================================

@app.post("/api/v1/categorize", response_model=BaseResponse)
async def categorize_item(request: BaseRequest, db: Session = Depends(get_db)):
    """
    Predicts the category for a given grocery item name.

    Uses zero-shot classification to match items to categories.
    When USE_REAL_CLASSIFICATION=true, uses the Hugging Face transformers model.
    Otherwise returns mock data for development.
    """
    global classifier
    start_time = time.time()

    try:
        payload = CategorizationRequestPayload(**request.payload)

        if settings.USE_REAL_CLASSIFICATION and classifier is not None:
            # Real Zero-Shot Classification
            model_id = settings.CLASSIFICATION_MODEL
            model_version = "transformers"

            result = classifier(
                payload.item_name,
                candidate_labels=payload.candidate_labels,
                multi_label=False
            )

            predicted_category = result["labels"][0]
            confidence = result["scores"][0]
            all_scores = dict(zip(result["labels"], [round(s, 4) for s in result["scores"]]))

            logger.info(
                f"Classified '{payload.item_name}' as '{predicted_category}' "
                f"with confidence {confidence:.2f}"
            )
        else:
            # MOCK IMPLEMENTATION for development
            model_id = "mock-classifier"
            model_version = "1.0.0"

            predicted_category = "Produce"
            confidence = 0.95

            item_lower = payload.item_name.lower()
            if "milk" in item_lower:
                predicted_category = "Dairy"
            elif "bread" in item_lower:
                predicted_category = "Bakery"
            elif "chicken" in item_lower:
                predicted_category = "Meat"

            # Build mock all_scores
            all_scores = {label: 0.02 for label in payload.candidate_labels}
            all_scores[predicted_category] = confidence

        # Determine confidence level
        if confidence >= 0.80:
            confidence_level = "high"
        elif confidence >= 0.50:
            confidence_level = "medium"
        else:
            confidence_level = "low"

        response_payload = CategorizationResponsePayload(
            category=predicted_category,
            confidence=confidence
        )

        latency_ms = (time.time() - start_time) * 1000

        # Store artifact
        create_artifact(
            db=db,
            request_id=request.request_id,
            tenant_id=request.tenant_id,
            user_id=request.user_id,
            feature="categorization",
            input_payload=request.payload,
            output_payload={
                **response_payload.model_dump(),
                "confidence_level": confidence_level,
                "all_scores": all_scores,
                "processing_time_ms": round(latency_ms, 2)
            },
            status="success",
            model_id=model_id,
            model_version=model_version,
            latency_ms=latency_ms,
        )

        return BaseResponse(
            request_id=request.request_id,
            payload={
                **response_payload.model_dump(),
                "confidence_level": confidence_level,
                "all_scores": all_scores,
                "processing_time_ms": round(latency_ms, 2)
            }
        )

    except Exception as e:
        latency_ms = (time.time() - start_time) * 1000
        logger.error(f"Error processing request {request.request_id}: {str(e)}")

        # Store error artifact
        create_artifact(
            db=db,
            request_id=request.request_id,
            tenant_id=request.tenant_id,
            user_id=request.user_id,
            feature="categorization",
            input_payload=request.payload,
            status="error",
            error_message=str(e),
            model_id=settings.CLASSIFICATION_MODEL if settings.USE_REAL_CLASSIFICATION else "mock-classifier",
            model_version="transformers" if settings.USE_REAL_CLASSIFICATION else "1.0.0",
            latency_ms=latency_ms,
        )

        return BaseResponse(
            request_id=request.request_id,
            status="error",
            payload={},
            error=str(e)
        )


@app.post("/api/v1/categorize-batch", response_model=BaseResponse)
async def categorize_batch(request: BaseRequest, db: Session = Depends(get_db)):
    """
    Predicts categories for a batch of grocery items.

    Processes up to 50 items in a single request.
    """
    global classifier
    start_time = time.time()

    try:
        payload = BatchCategorizationRequestPayload(**request.payload)

        if len(payload.items) > 50:
            raise ValueError("Batch size exceeds maximum of 50 items")

        predictions = []

        for item in payload.items:
            if settings.USE_REAL_CLASSIFICATION and classifier is not None:
                model_id = settings.CLASSIFICATION_MODEL
                model_version = "transformers"

                result = classifier(
                    item.name,
                    candidate_labels=payload.candidate_labels,
                    multi_label=False
                )

                predicted_category = result["labels"][0]
                confidence = result["scores"][0]
            else:
                # MOCK IMPLEMENTATION for development
                model_id = "mock-classifier"
                model_version = "1.0.0"

                predicted_category = "Produce"
                confidence = 0.95

                item_lower = item.name.lower()
                if "milk" in item_lower:
                    predicted_category = "Dairy"
                    confidence = 0.94
                elif "bread" in item_lower:
                    predicted_category = "Bakery"
                    confidence = 0.91
                elif "chicken" in item_lower:
                    predicted_category = "Meat & Seafood"
                    confidence = 0.88

            # Determine confidence level
            if confidence >= 0.80:
                confidence_level = "high"
            elif confidence >= 0.50:
                confidence_level = "medium"
            else:
                confidence_level = "low"

            predictions.append(BatchPrediction(
                id=item.id,
                name=item.name,
                predicted_category=predicted_category,
                confidence=confidence,
                confidence_level=confidence_level,
            ))

        processing_time_ms = (time.time() - start_time) * 1000

        response_payload = BatchCategorizationResponsePayload(
            predictions=predictions,
            processing_time_ms=processing_time_ms,
        )

        # Store artifact
        create_artifact(
            db=db,
            request_id=request.request_id,
            tenant_id=request.tenant_id,
            user_id=request.user_id,
            feature="categorization_batch",
            input_payload=request.payload,
            output_payload=response_payload.model_dump(),
            status="success",
            model_id=model_id if payload.items else "none",
            model_version=model_version if payload.items else "none",
            latency_ms=processing_time_ms,
        )

        return BaseResponse(
            request_id=request.request_id,
            payload=response_payload.model_dump()
        )

    except Exception as e:
        processing_time_ms = (time.time() - start_time) * 1000
        logger.error(f"Error processing batch request {request.request_id}: {str(e)}")

        create_artifact(
            db=db,
            request_id=request.request_id,
            tenant_id=request.tenant_id,
            user_id=request.user_id,
            feature="categorization_batch",
            input_payload=request.payload,
            status="error",
            error_message=str(e),
            model_id=settings.CLASSIFICATION_MODEL if settings.USE_REAL_CLASSIFICATION else "mock-classifier",
            model_version="transformers" if settings.USE_REAL_CLASSIFICATION else "1.0.0",
            latency_ms=processing_time_ms,
        )

        return BaseResponse(
            request_id=request.request_id,
            status="error",
            payload={},
            error=str(e)
        )


@app.post("/api/v1/extract-receipt", response_model=BaseResponse)
async def extract_receipt_endpoint(request: BaseRequest, db: Session = Depends(get_db)):
    """
    Extracts items from a receipt image.

    Uses OCR and layout analysis to identify line items, prices, and totals.
    When USE_VLLM_OCR=true, uses vLLM-served VLM for real OCR.
    Otherwise returns mock data for development.
    """
    start_time = time.time()

    try:
        payload = ExtractionRequestPayload(**request.payload)

        if settings.USE_VLLM_OCR:
            # Real OCR via vLLM
            from ocr_service import extract_receipt

            model_id = settings.VLLM_MODEL
            model_version = "vllm"

            # Get image data
            if payload.image_base64:
                image_b64 = payload.image_base64
            elif payload.image_url:
                # Fetch image from URL
                import httpx
                async with httpx.AsyncClient() as client:
                    resp = await client.get(payload.image_url)
                    import base64
                    image_b64 = base64.b64encode(resp.content).decode()
            else:
                raise ValueError("Either image_base64 or image_url required")

            result = await extract_receipt(image_b64)

            response_payload = ExtractionResponsePayload(
                items=[ExtractedItem(**item) for item in result["items"]],
                total=result["total"],
                merchant=result["merchant"],
                date=result["date"],
                currency=result.get("currency", "USD"),
                raw_ocr_text=result.get("raw_ocr_text", ""),
                overall_confidence=result.get("overall_confidence", 0.0),
            )
        elif settings.USE_TESSERACT_OCR:
            # Tesseract OCR fallback
            import base64 as b64_mod
            import tempfile
            import os

            if _tesseract_process_receipt is None:
                raise HTTPException(
                    status_code=503,
                    detail="Tesseract OCR is not installed. Install tesseract-ocr package."
                )

            try:
                # Decode base64 image to temp file
                image_bytes = b64_mod.b64decode(payload.image_base64)
                with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as tmp:
                    tmp.write(image_bytes)
                    tmp_path = tmp.name

                try:
                    result = _tesseract_process_receipt(tmp_path)

                    # Transform ExtractionResult -> ExtractionResponsePayload (flat format)
                    flat_items = []
                    for li in result.line_items:
                        price_val = None
                        if li.total_price and li.total_price.amount:
                            try:
                                price_val = float(li.total_price.amount)
                            except (ValueError, TypeError):
                                pass
                        elif li.unit_price and li.unit_price.amount:
                            try:
                                price_val = float(li.unit_price.amount)
                            except (ValueError, TypeError):
                                pass

                        flat_items.append(ExtractedItem(
                            name=li.parsed_name or li.raw_text,
                            quantity=li.quantity or 1.0,
                            unit=li.unit,
                            price=price_val,
                            confidence=li.confidence,
                        ))

                    total_val = None
                    if result.total and result.total.amount:
                        try:
                            total_val = float(result.total.amount)
                        except (ValueError, TypeError):
                            pass

                    merchant_val = result.merchant.name if result.merchant else None
                    date_val = result.date.value if result.date else None
                    # The full ExtractionResult holds these; stop discarding them
                    # to fit the narrow shape (AI-006 §5).
                    currency_val = result.total.currency if result.total else "USD"

                    response_payload = ExtractionResponsePayload(
                        items=flat_items,
                        total=total_val,
                        merchant=merchant_val,
                        date=date_val,
                        currency=currency_val,
                        raw_ocr_text=result.raw_ocr_text,
                        overall_confidence=result.overall_confidence,
                    )

                    model_id = "tesseract-ocr"
                    try:
                        import pytesseract
                        tv = pytesseract.get_tesseract_version()
                        model_version = f"tesseract-{tv}"
                    except Exception:
                        model_version = "tesseract-5.x"

                finally:
                    os.unlink(tmp_path)

            except HTTPException:
                raise
            except FileNotFoundError:
                raise HTTPException(
                    status_code=503,
                    detail="Tesseract OCR is not installed. Install tesseract-ocr package."
                )
            except Exception as e:
                logger.error(f"Tesseract OCR failed: {e}")
                raise HTTPException(status_code=500, detail=f"OCR processing failed: {str(e)}")
        else:
            # Mock response for development/CI without OCR
            model_id = "mock-ocr"
            model_version = "1.0.0"

            mock_items = [
                ExtractedItem(name="Bananas", quantity=1.0, unit="bunch", price=1.99, confidence=0.98),
                ExtractedItem(name="Milk", quantity=1.0, unit="gallon", price=3.49, confidence=0.95)
            ]

            response_payload = ExtractionResponsePayload(
                items=mock_items,
                total=5.48,
                merchant="Mock Supermarket",
                date="2024-01-01",
                currency="USD",
                raw_ocr_text="Mock Supermarket\nBananas 1.99\nMilk 3.49",
                overall_confidence=0.95,
            )

        latency_ms = (time.time() - start_time) * 1000

        # Surface model + timing on the wire (all branches). These were already
        # computed for the artifact write; the flat contract now returns them so
        # the Elixir receipt's model_version / processing_time_ms columns stop
        # being permanently nil (AI-006 §5).
        response_payload.model_version = model_version
        response_payload.processing_time_ms = latency_ms

        # Store artifact
        create_artifact(
            db=db,
            request_id=request.request_id,
            tenant_id=request.tenant_id,
            user_id=request.user_id,
            feature="receipt_extraction",
            input_payload=request.payload,
            output_payload=response_payload.model_dump(),
            status="success",
            model_id=model_id,
            model_version=model_version,
            latency_ms=latency_ms,
        )

        return BaseResponse(
            request_id=request.request_id,
            payload=response_payload.model_dump()
        )

    except Exception as e:
        latency_ms = (time.time() - start_time) * 1000
        logger.error(f"Error extracting receipt {request.request_id}: {str(e)}")

        create_artifact(
            db=db,
            request_id=request.request_id,
            tenant_id=request.tenant_id,
            user_id=request.user_id,
            feature="receipt_extraction",
            input_payload=request.payload,
            status="error",
            error_message=str(e),
            model_id=(
                settings.VLLM_MODEL if settings.USE_VLLM_OCR
                else "tesseract-ocr" if settings.USE_TESSERACT_OCR
                else "mock-ocr"
            ),
            model_version=(
                "vllm" if settings.USE_VLLM_OCR
                else "tesseract-5.x" if settings.USE_TESSERACT_OCR
                else "1.0.0"
            ),
            latency_ms=latency_ms,
        )

        return BaseResponse(
            request_id=request.request_id,
            status="error",
            payload={},
            error=str(e)
        )


@app.post("/api/v1/embed", response_model=EmbedResponse)
async def generate_embeddings(request: EmbedRequest):
    """
    Generates vector embeddings for the given texts.

    Uses sentence-transformers/all-MiniLM-L6-v2 model to create 384-dimensional
    semantic embeddings for search and similarity tasks.
    """
    start_time = time.time()

    try:
        if not request.texts:
            raise ValueError("At least one text item required")

        # Load embedding model (lazy initialization)
        model = get_embedding_model()

        # Extract texts in order
        texts = [item.text for item in request.texts]

        # Generate embeddings with normalization
        vectors = model.encode(texts, normalize_embeddings=True)

        # Build response
        embeddings = [
            EmbeddingResult(id=item.id, vector=vec.tolist())
            for item, vec in zip(request.texts, vectors)
        ]

        latency_ms = (time.time() - start_time) * 1000

        logger.info(
            f"Generated {len(embeddings)} embeddings in {latency_ms:.2f}ms "
            f"(request_id={request.request_id})"
        )

        return EmbedResponse(
            version=request.version,
            request_id=request.request_id,
            model="all-MiniLM-L6-v2",
            dimension=vectors.shape[1],
            embeddings=embeddings
        )

    except Exception as e:
        latency_ms = (time.time() - start_time) * 1000
        logger.error(f"Error generating embeddings {request.request_id}: {str(e)}")
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/api/v1/embed/batch", response_model=EmbedResponse)
async def generate_embeddings_batch(request: EmbedBatchRequest):
    """
    Generates vector embeddings for a large batch of texts.

    Processes texts in configurable batches for memory efficiency.
    Useful for bulk embedding operations with hundreds or thousands of texts.
    """
    start_time = time.time()

    try:
        if not request.texts:
            raise ValueError("At least one text item required")

        if request.batch_size < 1:
            raise ValueError("batch_size must be >= 1")

        # Load embedding model (lazy initialization)
        model = get_embedding_model()

        # Extract texts in order
        texts = [item.text for item in request.texts]

        # Process in batches for memory efficiency
        all_vectors = []
        for i in range(0, len(texts), request.batch_size):
            batch = texts[i:i + request.batch_size]
            vectors = model.encode(batch, normalize_embeddings=True)
            all_vectors.extend(vectors)

        # Build response
        embeddings = [
            EmbeddingResult(id=item.id, vector=vec.tolist())
            for item, vec in zip(request.texts, all_vectors)
        ]

        latency_ms = (time.time() - start_time) * 1000

        logger.info(
            f"Generated {len(embeddings)} embeddings in batches of {request.batch_size} "
            f"in {latency_ms:.2f}ms (request_id={request.request_id})"
        )

        return EmbedResponse(
            version=request.version,
            request_id=request.request_id,
            model="all-MiniLM-L6-v2",
            dimension=384,
            embeddings=embeddings
        )

    except Exception as e:
        latency_ms = (time.time() - start_time) * 1000
        logger.error(f"Error generating batch embeddings {request.request_id}: {str(e)}")
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/api/v1/optimize/meal-plan", response_model=BaseResponse)
async def optimize_meal_plan_endpoint(request: BaseRequest, db: Session = Depends(get_db)):
    """Generate an optimized meal plan using Z3 SMT solver."""
    start_time = time.time()
    try:
        payload = MealOptimizationRequestPayload(**request.payload)

        problem = {
            "planning_horizon": payload.planning_horizon.model_dump(),
            "inventory": [item.model_dump() for item in payload.inventory],
            "recipes": [recipe.model_dump() for recipe in payload.recipes],
            "constraints": payload.constraints.model_dump(),
            "weights": payload.weights.model_dump(),
        }

        result = optimize_meal_plan(problem, timeout_ms=5000)
        latency_ms = (time.time() - start_time) * 1000

        if result.get("status") == "optimal":
            response_payload = {
                "status": result["status"],
                "solve_time_ms": result.get("solve_time_ms", 0),
                **result.get("solution", {}),
            }
        else:
            response_payload = {
                "status": result.get("status", "no_solution"),
                "solve_time_ms": result.get("solve_time_ms", 0),
                "meal_plan": [],
                "shopping_list": [],
                "metrics": {},
                "explanation": [],
            }

        create_artifact(
            db=db,
            request_id=request.request_id,
            tenant_id=request.tenant_id,
            user_id=request.user_id,
            feature="meal_optimization",
            status="success" if result.get("status") == "optimal" else "no_solution",
            input_data=request.payload,
            output_data=response_payload,
            latency_ms=latency_ms,
        )

        return BaseResponse(
            request_id=request.request_id,
            status="success",
            payload=response_payload,
        )
    except Exception as e:
        logger.error(f"Meal optimization error: {e}")
        latency_ms = (time.time() - start_time) * 1000
        create_artifact(
            db=db,
            request_id=request.request_id,
            tenant_id=request.tenant_id,
            user_id=request.user_id,
            feature="meal_optimization",
            status="error",
            input_data=request.payload,
            output_data={},
            latency_ms=latency_ms,
            error_message=str(e),
        )
        return BaseResponse(
            request_id=request.request_id,
            status="error",
            error=str(e),
            payload={},
        )


@app.post("/api/v1/optimize/suggestions", response_model=BaseResponse)
async def optimize_suggestions_endpoint(request: BaseRequest, db: Session = Depends(get_db)):
    """Get quick recipe suggestions based on inventory and preferences."""
    start_time = time.time()
    try:
        payload = QuickSuggestionRequestPayload(**request.payload)

        inventory = [item.model_dump() for item in payload.inventory]
        recipes = [recipe.model_dump() for recipe in payload.recipes]

        suggestions = quick_suggestions(
            inventory=inventory,
            recipes=recipes,
            mode=payload.mode,
            limit=payload.limit,
        )

        latency_ms = (time.time() - start_time) * 1000
        response_payload = {"suggestions": suggestions}

        create_artifact(
            db=db,
            request_id=request.request_id,
            tenant_id=request.tenant_id,
            user_id=request.user_id,
            feature="meal_suggestions",
            status="success",
            input_data=request.payload,
            output_data=response_payload,
            latency_ms=latency_ms,
        )

        return BaseResponse(
            request_id=request.request_id,
            status="success",
            payload=response_payload,
        )
    except Exception as e:
        logger.error(f"Meal suggestion error: {e}")
        latency_ms = (time.time() - start_time) * 1000
        create_artifact(
            db=db,
            request_id=request.request_id,
            tenant_id=request.tenant_id,
            user_id=request.user_id,
            feature="meal_suggestions",
            status="error",
            input_data=request.payload,
            output_data={},
            latency_ms=latency_ms,
            error_message=str(e),
        )
        return BaseResponse(
            request_id=request.request_id,
            status="error",
            error=str(e),
            payload={},
        )


@app.post("/api/v1/receipts/extract", response_model=ReceiptExtractResponse)
async def extract_receipt_ocr(request: ReceiptExtractRequest):
    """
    Extract structured data from receipt image using Tesseract OCR.

    This is the MVP implementation using Tesseract + regex parsing.
    Processes local image files and returns extracted merchant, date, total, and line items.

    Future: Will be enhanced with LayoutLM for better accuracy.
    """
    start_time = time.time()

    try:
        from receipt_ocr import process_receipt

        logger.info(
            f"Processing receipt OCR request {request.request_id} "
            f"for account {request.account_id}, image: {request.image_path}"
        )

        # Process the receipt
        extraction_result = process_receipt(request.image_path, request.options)

        processing_time_ms = (time.time() - start_time) * 1000

        # Get Tesseract version for model_version field
        try:
            import pytesseract
            tesseract_version = pytesseract.get_tesseract_version()
            model_version = f"tesseract-{tesseract_version.major}.{tesseract_version.minor}"
        except Exception:
            model_version = "tesseract-5.x"

        response = ReceiptExtractResponse(
            version=request.version,
            request_id=request.request_id,
            status="success",
            processing_time_ms=processing_time_ms,
            model_version=model_version,
            extraction=extraction_result
        )

        logger.info(
            f"Receipt OCR completed in {processing_time_ms:.2f}ms, "
            f"confidence={extraction_result.overall_confidence:.2f}, "
            f"items={len(extraction_result.line_items)}"
        )

        return response

    except FileNotFoundError as e:
        processing_time_ms = (time.time() - start_time) * 1000
        logger.error(f"File not found for request {request.request_id}: {str(e)}")
        raise HTTPException(status_code=404, detail=f"Image file not found: {str(e)}")

    except RuntimeError as e:
        processing_time_ms = (time.time() - start_time) * 1000
        error_msg = str(e)
        logger.error(f"Runtime error for request {request.request_id}: {error_msg}")

        if "Tesseract" in error_msg:
            raise HTTPException(
                status_code=503,
                detail="OCR service unavailable. Tesseract is not installed."
            )
        raise HTTPException(status_code=500, detail=error_msg)

    except ValueError as e:
        processing_time_ms = (time.time() - start_time) * 1000
        logger.error(f"Invalid image for request {request.request_id}: {str(e)}")
        raise HTTPException(status_code=400, detail=f"Invalid or corrupt image: {str(e)}")

    except Exception as e:
        processing_time_ms = (time.time() - start_time) * 1000
        logger.error(f"Unexpected error processing receipt {request.request_id}: {str(e)}")
        raise HTTPException(status_code=500, detail=f"Receipt processing failed: {str(e)}")


# =============================================================================
# Job Management Endpoints
# =============================================================================

@app.post("/api/v1/jobs", response_model=JobStatusResponse)
async def submit_async_job(request: JobSubmitRequest, db: Session = Depends(get_db)):
    """
    Submit a job for background processing.

    Returns immediately with a job ID that can be polled for status.
    """
    job = submit_job(
        db=db,
        tenant_id=request.tenant_id,
        user_id=request.user_id,
        feature=request.feature,
        input_payload=request.payload,
        model_id=request.model_id,
        model_version=request.model_version,
    )

    return JobStatusResponse(
        job_id=job.id,
        status=job.status.value,
        feature=job.feature,
        created_at=job.created_at.isoformat(),
    )


@app.get("/api/v1/jobs/{job_id}", response_model=JobStatusResponse)
async def get_job_status(
    job_id: str,
    tenant_id: str = Query(..., description="Tenant ID for access control"),
    db: Session = Depends(get_db)
):
    """
    Get the status of a background job.

    Returns full job details including output if completed.
    """
    job = get_job(db, job_id, tenant_id)
    if not job:
        raise HTTPException(status_code=404, detail="Job not found")

    return JobStatusResponse(**job_to_dict(job))


@app.get("/api/v1/jobs", response_model=JobListResponse)
async def list_tenant_jobs(
    tenant_id: str = Query(..., description="Tenant ID for access control"),
    feature: Optional[str] = Query(None, description="Filter by feature"),
    status: Optional[str] = Query(None, description="Filter by status"),
    limit: int = Query(50, ge=1, le=100),
    offset: int = Query(0, ge=0),
    db: Session = Depends(get_db)
):
    """
    List jobs for a tenant.

    Supports filtering by feature and status with pagination.
    """
    status_enum = JobStatus(status) if status else None
    jobs = list_jobs(db, tenant_id, feature=feature, status=status_enum, limit=limit, offset=offset)

    return JobListResponse(
        jobs=[job_to_dict(job) for job in jobs],
        total=len(jobs),
        limit=limit,
        offset=offset,
    )


# =============================================================================
# Artifact Endpoints
# =============================================================================

@app.get("/api/v1/artifacts/{artifact_id}", response_model=ArtifactResponse)
async def get_artifact_details(
    artifact_id: str,
    tenant_id: str = Query(..., description="Tenant ID for access control"),
    db: Session = Depends(get_db)
):
    """
    Get details of an AI artifact.

    Returns full artifact including input/output payloads.
    """
    artifact = get_artifact(db, artifact_id, tenant_id)
    if not artifact:
        raise HTTPException(status_code=404, detail="Artifact not found")

    return ArtifactResponse(**artifact_to_dict(artifact))


@app.get("/api/v1/artifacts", response_model=ArtifactListResponse)
async def list_tenant_artifacts(
    tenant_id: str = Query(..., description="Tenant ID for access control"),
    feature: Optional[str] = Query(None, description="Filter by feature"),
    status: Optional[str] = Query(None, description="Filter by status"),
    limit: int = Query(50, ge=1, le=100),
    offset: int = Query(0, ge=0),
    db: Session = Depends(get_db)
):
    """
    List artifacts for a tenant.

    Supports filtering by feature and status with pagination.
    """
    artifacts = list_artifacts(db, tenant_id, feature=feature, status=status, limit=limit, offset=offset)

    return ArtifactListResponse(
        artifacts=[artifact_to_dict(a) for a in artifacts],
        total=len(artifacts),
        limit=limit,
        offset=offset,
    )


# =============================================================================
# Feedback Endpoints
# =============================================================================

@app.post("/api/v1/feedback", response_model=FeedbackResponse)
async def submit_feedback(request: FeedbackRequest, db: Session = Depends(get_db)):
    """
    Submit feedback for an AI operation.

    Accepts thumbs up/down ratings with optional notes.
    """
    feedback = add_feedback(
        db=db,
        tenant_id=request.tenant_id,
        user_id=request.user_id,
        rating=request.rating,
        note=request.note,
        artifact_id=request.artifact_id,
        job_id=request.job_id,
    )

    return FeedbackResponse(**feedback_to_dict(feedback))


# =============================================================================
# Register Job Handlers
# =============================================================================

@register_job_handler("receipt_extraction")
async def handle_receipt_extraction(input_payload: dict) -> dict:
    """Background handler for receipt extraction jobs."""
    if settings.USE_VLLM_OCR:
        from ocr_service import extract_receipt

        image_b64 = input_payload.get("image_base64")
        if not image_b64:
            raise ValueError("image_base64 required in payload")

        return await extract_receipt(image_b64)
    else:
        # MOCK IMPLEMENTATION for development
        return {
            "items": [
                {"name": "Bananas", "quantity": 1.0, "unit": "bunch", "price": 1.99, "confidence": 0.98},
                {"name": "Milk", "quantity": 1.0, "unit": "gallon", "price": 3.49, "confidence": 0.95}
            ],
            "total": 5.48,
            "merchant": "Mock Supermarket",
            "date": "2024-01-01"
        }


@register_job_handler("embedding_batch")
async def handle_embedding_batch(input_payload: dict) -> dict:
    """Background handler for batch embedding jobs."""
    texts = input_payload.get("texts", [])
    # MOCK IMPLEMENTATION
    return {
        "vectors": [[0.1] * 384 for _ in texts],
        "count": len(texts)
    }
