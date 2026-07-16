"""
Pydantic schemas for AI service request/response contracts.

All schemas are versioned and designed for backward compatibility.
"""

from pydantic import BaseModel, Field
from typing import List, Optional, Dict, Any


# =============================================================================
# Base Schemas
# =============================================================================

class BaseRequest(BaseModel):
    """Base request schema for all AI operations."""
    request_id: str = Field(..., description="Unique request identifier for tracing")
    tenant_id: str = Field(..., description="Tenant (account) ID for multi-tenancy")
    user_id: Optional[str] = Field(default=None, description="User ID who initiated the request (null for system-initiated)")
    feature: str = Field(..., description="Feature name (e.g., 'categorization', 'embedding')")
    payload: Dict[str, Any] = Field(..., description="Feature-specific payload")
    metadata: Optional[Dict[str, Any]] = Field(default={}, description="Optional metadata")


class BaseResponse(BaseModel):
    """Base response schema for all AI operations."""
    request_id: str = Field(..., description="Original request ID for correlation")
    status: str = Field(default="success", description="Status: 'success' or 'error'")
    payload: Dict[str, Any] = Field(..., description="Feature-specific response payload")
    error: Optional[str] = Field(default=None, description="Error message if status is 'error'")
    metadata: Optional[Dict[str, Any]] = Field(default={}, description="Optional response metadata")


# =============================================================================
# Feature: Smart Categorization
# =============================================================================

class CategorizationRequestPayload(BaseModel):
    """Payload for item categorization requests."""
    item_name: str = Field(..., description="Name of the grocery item to categorize")
    candidate_labels: List[str] = Field(..., description="List of possible category labels")


class CategorizationResponsePayload(BaseModel):
    """Payload for item categorization responses."""
    category: str = Field(..., description="Predicted category")
    confidence: float = Field(..., ge=0, le=1, description="Confidence score (0-1)")


class BatchCategorizationItem(BaseModel):
    """A single item in a batch categorization request."""
    id: str = Field(..., description="Unique identifier for this item")
    name: str = Field(..., description="Grocery item name to categorize")


class BatchCategorizationRequestPayload(BaseModel):
    """Payload for batch item categorization requests."""
    items: List[BatchCategorizationItem] = Field(..., description="Items to categorize")
    candidate_labels: List[str] = Field(..., description="List of possible category labels")


class BatchPrediction(BaseModel):
    """A single prediction in a batch categorization response."""
    id: str = Field(..., description="Item identifier from request")
    name: str = Field(..., description="Original item name")
    predicted_category: str = Field(..., description="Predicted category")
    confidence: float = Field(..., ge=0, le=1, description="Confidence score")
    confidence_level: str = Field(..., description="Confidence level: high/medium/low")


class BatchCategorizationResponsePayload(BaseModel):
    """Payload for batch item categorization responses."""
    predictions: List[BatchPrediction] = Field(..., description="Predictions for each item")
    processing_time_ms: float = Field(..., description="Total processing time in milliseconds")


# =============================================================================
# Feature: Receipt Extraction
# =============================================================================

class ExtractionRequestPayload(BaseModel):
    """Payload for receipt extraction requests."""
    image_url: Optional[str] = Field(default=None, description="URL to receipt image")
    image_base64: Optional[str] = Field(default=None, description="Base64-encoded receipt image")


class ExtractedItem(BaseModel):
    """A single item extracted from a receipt."""
    name: str = Field(..., description="Item name")
    quantity: float = Field(..., description="Quantity purchased")
    unit: Optional[str] = Field(default=None, description="Unit of measure")
    price: Optional[float] = Field(default=None, description="Item price")
    confidence: float = Field(..., ge=0, le=1, description="Extraction confidence (0-1)")


class ExtractionResponsePayload(BaseModel):
    """Payload for receipt extraction responses (the flat wire contract).

    This is the ONLY receipt shape the Elixir app consumes
    (GroceryPlanner.Inventory.ReceiptProcessor). Every field here has a
    consumer on the Elixir side; adding/renaming a field is a contract change
    that both `test_extraction_response_payload_contract` (Python) and
    `receipt_processor_test.exs` (Elixir) pin. Currency is hoisted to the
    payload (one currency per receipt), not carried per-item.
    """
    items: List[ExtractedItem] = Field(..., description="Extracted line items")
    total: Optional[float] = Field(default=None, description="Receipt total if detected")
    merchant: Optional[str] = Field(default=None, description="Merchant name if detected")
    date: Optional[str] = Field(default=None, description="Purchase date if detected")
    currency: str = Field(default="USD", description="ISO-4217 currency code for all amounts on this receipt")
    raw_ocr_text: str = Field(default="", description="Full raw OCR output")
    overall_confidence: float = Field(default=0.0, ge=0, le=1, description="Overall extraction confidence (0-1)")
    model_version: Optional[str] = Field(default=None, description="OCR engine/model version that produced this result")
    processing_time_ms: Optional[float] = Field(default=None, description="Server-side processing time in milliseconds")


# =============================================================================
# Feature: Semantic Search / Embeddings
# =============================================================================

class EmbeddingRequestPayload(BaseModel):
    """Payload for embedding generation requests."""
    text: str = Field(..., description="Text to embed")


class EmbeddingResponsePayload(BaseModel):
    """Payload for embedding generation responses."""
    vector: List[float] = Field(..., description="Embedding vector")


class EmbedTextItem(BaseModel):
    """A single text item to embed."""
    id: str = Field(..., description="Unique identifier for this text")
    text: str = Field(..., description="Text to embed")


class EmbedRequest(BaseModel):
    """Request for generating embeddings."""
    version: str = Field(default="1.0", description="API version")
    request_id: str = Field(..., description="Unique request identifier")
    texts: List[EmbedTextItem] = Field(..., description="List of texts to embed")


class EmbedBatchRequest(BaseModel):
    """Request for batch embedding generation with configurable batch size."""
    version: str = Field(default="1.0", description="API version")
    request_id: str = Field(..., description="Unique request identifier")
    texts: List[EmbedTextItem] = Field(..., description="List of texts to embed")
    batch_size: int = Field(default=32, description="Batch size for processing")


class EmbeddingResult(BaseModel):
    """A single embedding result."""
    id: str = Field(..., description="Text identifier from request")
    vector: List[float] = Field(..., description="Embedding vector")


class EmbedResponse(BaseModel):
    """Response containing generated embeddings."""
    version: str = Field(default="1.0", description="API version")
    request_id: str = Field(..., description="Original request identifier")
    model: str = Field(..., description="Model name used for embeddings")
    dimension: int = Field(..., description="Dimension of embedding vectors")
    embeddings: List[EmbeddingResult] = Field(..., description="Generated embeddings")


# =============================================================================
# Job Management Schemas
# =============================================================================

class JobSubmitRequest(BaseModel):
    """Request to submit a background job."""
    tenant_id: str = Field(..., description="Tenant ID for multi-tenancy")
    user_id: str = Field(..., description="User ID who submitted the job")
    feature: str = Field(..., description="Feature name for the job")
    payload: Dict[str, Any] = Field(..., description="Job input payload")
    model_id: Optional[str] = Field(default=None, description="Specific model to use")
    model_version: Optional[str] = Field(default=None, description="Specific model version")


class JobStatusResponse(BaseModel):
    """Response containing job status and details."""
    id: Optional[str] = Field(default=None, alias="job_id", description="Job ID")
    job_id: Optional[str] = Field(default=None, description="Job ID (deprecated, use id)")
    tenant_id: Optional[str] = Field(default=None, description="Tenant ID")
    user_id: Optional[str] = Field(default=None, description="User who submitted")
    feature: str = Field(..., description="Feature name")
    status: str = Field(..., description="Job status: queued, running, succeeded, failed")
    input_payload: Optional[Dict[str, Any]] = Field(default=None, description="Job input")
    output_payload: Optional[Dict[str, Any]] = Field(default=None, description="Job output (if completed)")
    error_message: Optional[str] = Field(default=None, description="Error message (if failed)")
    model_id: Optional[str] = Field(default=None, description="Model used")
    model_version: Optional[str] = Field(default=None, description="Model version used")
    created_at: Optional[str] = Field(default=None, description="Creation timestamp")
    started_at: Optional[str] = Field(default=None, description="Start timestamp")
    finished_at: Optional[str] = Field(default=None, description="Completion timestamp")
    latency_ms: Optional[float] = Field(default=None, description="Execution latency in ms")
    cost: Optional[float] = Field(default=None, description="Operation cost")

    class Config:
        populate_by_name = True


class JobListResponse(BaseModel):
    """Response containing a list of jobs."""
    jobs: List[Dict[str, Any]] = Field(..., description="List of job records")
    total: int = Field(..., description="Total jobs returned")
    limit: int = Field(..., description="Limit used")
    offset: int = Field(..., description="Offset used")


# =============================================================================
# Artifact Schemas
# =============================================================================

class ArtifactResponse(BaseModel):
    """Response containing artifact details."""
    id: str = Field(..., description="Artifact ID")
    request_id: str = Field(..., description="Original request ID")
    tenant_id: str = Field(..., description="Tenant ID")
    user_id: Optional[str] = Field(default=None, description="User ID (null for system-initiated)")
    feature: str = Field(..., description="Feature name")
    input_payload: Optional[Dict[str, Any]] = Field(default=None, description="Input data")
    output_payload: Optional[Dict[str, Any]] = Field(default=None, description="Output data")
    status: str = Field(..., description="Operation status")
    error_message: Optional[str] = Field(default=None, description="Error message if failed")
    model_id: Optional[str] = Field(default=None, description="Model used")
    model_version: Optional[str] = Field(default=None, description="Model version")
    latency_ms: Optional[float] = Field(default=None, description="Latency in ms")
    cost: Optional[float] = Field(default=None, description="Cost")
    job_id: Optional[str] = Field(default=None, description="Associated job ID")
    created_at: Optional[str] = Field(default=None, description="Creation timestamp")


class ArtifactListResponse(BaseModel):
    """Response containing a list of artifacts."""
    artifacts: List[Dict[str, Any]] = Field(..., description="List of artifact records")
    total: int = Field(..., description="Total artifacts returned")
    limit: int = Field(..., description="Limit used")
    offset: int = Field(..., description="Offset used")


# =============================================================================
# Feedback Schemas
# =============================================================================

class FeedbackRequest(BaseModel):
    """Request to submit feedback on an AI operation."""
    tenant_id: str = Field(..., description="Tenant ID")
    user_id: str = Field(..., description="User providing feedback")
    rating: str = Field(..., description="Rating: 'thumbs_up' or 'thumbs_down'")
    note: Optional[str] = Field(default=None, description="Optional feedback note")
    artifact_id: Optional[str] = Field(default=None, description="Associated artifact ID")
    job_id: Optional[str] = Field(default=None, description="Associated job ID")


class FeedbackResponse(BaseModel):
    """Response confirming feedback submission."""
    id: str = Field(..., description="Feedback ID")
    tenant_id: str = Field(..., description="Tenant ID")
    user_id: str = Field(..., description="User ID")
    rating: str = Field(..., description="Rating value")
    note: Optional[str] = Field(default=None, description="Feedback note")
    artifact_id: Optional[str] = Field(default=None, description="Associated artifact ID")
    job_id: Optional[str] = Field(default=None, description="Associated job ID")
    created_at: Optional[str] = Field(default=None, description="Creation timestamp")


# =============================================================================
# Feature: Receipt OCR Extraction
# =============================================================================

class ReceiptExtractRequest(BaseModel):
    """Request for OCR receipt extraction."""
    version: str = Field(default="1.0", description="API version")
    request_id: str = Field(..., description="Unique request identifier")
    account_id: str = Field(..., description="Account ID for multi-tenancy")
    image_path: str = Field(..., description="Local file path to receipt image")
    options: Dict[str, Any] = Field(default_factory=dict, description="Optional processing options")


class MerchantInfo(BaseModel):
    """Extracted merchant information."""
    name: Optional[str] = Field(default=None, description="Merchant name")
    confidence: float = Field(default=0.0, ge=0, le=1, description="Confidence score")


class DateInfo(BaseModel):
    """Extracted date information."""
    value: Optional[str] = Field(default=None, description="Date string")
    confidence: float = Field(default=0.0, ge=0, le=1, description="Confidence score")


class MoneyInfo(BaseModel):
    """Extracted monetary amount."""
    amount: Optional[str] = Field(default=None, description="Amount as string")
    currency: str = Field(default="USD", description="Currency code")
    confidence: float = Field(default=0.0, ge=0, le=1, description="Confidence score")


class LineItem(BaseModel):
    """A single line item from receipt."""
    raw_text: str = Field(..., description="Raw OCR text for this line")
    parsed_name: Optional[str] = Field(default=None, description="Parsed item name")
    quantity: Optional[float] = Field(default=None, description="Item quantity")
    unit: Optional[str] = Field(default=None, description="Unit of measure")
    unit_price: Optional[MoneyInfo] = Field(default=None, description="Price per unit")
    total_price: Optional[MoneyInfo] = Field(default=None, description="Total line price")
    confidence: float = Field(default=0.0, ge=0, le=1, description="Confidence score")


class ExtractionResult(BaseModel):
    """Complete extraction result."""
    merchant: MerchantInfo = Field(default_factory=MerchantInfo, description="Merchant info")
    date: DateInfo = Field(default_factory=DateInfo, description="Transaction date")
    total: MoneyInfo = Field(default_factory=MoneyInfo, description="Receipt total")
    line_items: List[LineItem] = Field(default_factory=list, description="Extracted line items")
    raw_ocr_text: str = Field(default="", description="Full raw OCR output")
    overall_confidence: float = Field(default=0.0, ge=0, le=1, description="Overall extraction quality")


class ReceiptExtractResponse(BaseModel):
    """Response containing receipt extraction results."""
    version: str = Field(default="1.0", description="API version")
    request_id: str = Field(..., description="Original request identifier")
    status: str = Field(default="success", description="Processing status")
    processing_time_ms: float = Field(..., description="Processing time in milliseconds")
    model_version: str = Field(default="tesseract-5.x", description="OCR engine version")
    extraction: ExtractionResult = Field(..., description="Extraction results")


# =============================================================================
# Feature: Meal Optimization
# =============================================================================

class InventoryItem(BaseModel):
    ingredient_id: str = Field(..., description="UUID of the grocery item")
    name: str = Field(..., description="Display name")
    quantity: float = Field(..., description="Available quantity")
    unit: str = Field(default="", description="Unit of measurement")
    days_until_expiry: Optional[int] = Field(default=None, description="Days until expiration")

class RecipeIngredient(BaseModel):
    ingredient_id: str = Field(..., description="UUID of the grocery item")
    name: str = Field(default="", description="Display name")
    quantity: float = Field(default=1.0, description="Required quantity")
    unit: str = Field(default="", description="Unit of measurement")

class OptimizationRecipe(BaseModel):
    id: str = Field(..., description="Recipe UUID")
    name: str = Field(..., description="Recipe name")
    prep_time: int = Field(default=0, description="Prep time in minutes")
    cook_time: int = Field(default=0, description="Cook time in minutes")
    ingredients: list[RecipeIngredient] = Field(default_factory=list)
    tags: list[str] = Field(default_factory=list)
    is_favorite: bool = Field(default=False)

class PlanningHorizon(BaseModel):
    start_date: str = Field(..., description="ISO date string for plan start")
    days: int = Field(default=7, description="Number of days to plan")
    meal_types: list[str] = Field(default_factory=lambda: ["dinner"])

class OptimizationConstraints(BaseModel):
    max_shopping_items: Optional[int] = Field(default=None, description="Max items to buy")
    time_budgets: dict[str, int] = Field(default_factory=dict, description="Date -> minutes budget")
    locked_meals: list[dict[str, str]] = Field(default_factory=list, description="Locked recipe-day pairs")
    excluded_recipes: list[str] = Field(default_factory=list, description="Recipe IDs to exclude")
    dietary: list[str] = Field(default_factory=list, description="Dietary restrictions")

class OptimizationWeights(BaseModel):
    expiring_priority: float = Field(default=0.4, ge=0, le=1)
    shopping_minimization: float = Field(default=0.3, ge=0, le=1)
    variety: float = Field(default=0.2, ge=0, le=1)
    time_fit: float = Field(default=0.1, ge=0, le=1)

class MealOptimizationRequestPayload(BaseModel):
    planning_horizon: PlanningHorizon
    inventory: list[InventoryItem] = Field(default_factory=list)
    recipes: list[OptimizationRecipe] = Field(default_factory=list)
    constraints: OptimizationConstraints = Field(default_factory=OptimizationConstraints)
    weights: OptimizationWeights = Field(default_factory=OptimizationWeights)

class MealPlanEntry(BaseModel):
    date: str = Field(..., description="ISO date string")
    day_index: int = Field(..., description="0-based day index")
    meal_type: str = Field(default="dinner")
    recipe_id: str = Field(...)
    recipe_name: str = Field(default="")

class ShoppingListItem(BaseModel):
    ingredient_id: str = Field(...)
    name: str = Field(default="")
    quantity: int = Field(default=1)

class OptimizationMetrics(BaseModel):
    expiring_ingredients_used: int = Field(default=0)
    total_expiring_ingredients: int = Field(default=0)
    shopping_items_count: int = Field(default=0)
    variety_score: float = Field(default=0.0)
    recipes_selected: int = Field(default=0)

class MealOptimizationResponsePayload(BaseModel):
    status: str = Field(...)
    solve_time_ms: int = Field(default=0)
    meal_plan: list[MealPlanEntry] = Field(default_factory=list)
    shopping_list: list[ShoppingListItem] = Field(default_factory=list)
    metrics: OptimizationMetrics = Field(default_factory=OptimizationMetrics)
    explanation: list[str] = Field(default_factory=list)

class QuickSuggestionRequestPayload(BaseModel):
    mode: str = Field(default="use_expiring", description="Suggestion mode")
    inventory: list[InventoryItem] = Field(default_factory=list)
    recipes: list[OptimizationRecipe] = Field(default_factory=list)
    limit: int = Field(default=5, ge=1, le=20)

class SuggestionItem(BaseModel):
    recipe_id: str = Field(...)
    recipe_name: str = Field(default="")
    score: float = Field(default=0.0)
    expiring_used: list[str] = Field(default_factory=list)
    missing: list[str] = Field(default_factory=list)
    reason: str = Field(default="")

class QuickSuggestionResponsePayload(BaseModel):
    suggestions: list[SuggestionItem] = Field(default_factory=list)
