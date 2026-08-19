"""External vision API adapter (M4-B).

Provider-agnostic implementation of `AIVisionPort` that delegates inference to
an external vision API (OpenAI, Google Gemini, etc.) via server-side HTTP.
The provider is selected through environment variables — no provider SDK is
required, and no API key ever reaches Flutter.

The adapter is pure perception: it maps image bytes to typed detections and
returns them. Product resolution, inventory mutation, and authorization remain
the service layer's responsibility.
"""
from __future__ import annotations

import base64
import json
import logging
import re
from decimal import Decimal
from typing import Protocol, runtime_checkable

import httpx

from app.ai.contract import DetectedItem, VisionContext
from app.config import get_settings

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Image format detection (magic bytes)
# ---------------------------------------------------------------------------

_JPEG_MAGIC = b"\xff\xd8\xff"
_PNG_MAGIC = b"\x89PNG"
_WEBP_MAGIC = b"RIFF"
_GIF_MAGIC = b"GIF8"

_IMAGE_MIME = {
    "jpeg": "image/jpeg",
    "png": "image/png",
    "webp": "image/webp",
    "gif": "image/gif",
}


def _detect_mime(data: bytes) -> str:
    """Best-effort MIME detection from magic bytes; falls back to JPEG."""
    if data[:3] == _JPEG_MAGIC:
        return _IMAGE_MIME["jpeg"]
    if data[:4] == _PNG_MAGIC:
        return _IMAGE_MIME["png"]
    if data[:4] == _WEBP_MAGIC and data[8:12] == b"WEBP":
        return _IMAGE_MIME["webp"]
    if data[:3] == _GIF_MAGIC:
        return _IMAGE_MIME["gif"]
    return _IMAGE_MIME["jpeg"]


# ---------------------------------------------------------------------------
# Provider protocol + concrete implementations
# ---------------------------------------------------------------------------

SYSTEM_PROMPT = (
    "You are an AI visual assistant for a retail inventory system. "
    "Analyze the provided image and identify all visible retail products.\n\n"
    "For EACH distinct product you see, return a JSON object with:\n"
    '- "name": the product full name (e.g. "Tiger Chips Hot Chili")\n'
    '- "brand": the brand name (e.g. "Tiger")\n'
    '- "barcode": the barcode/UPC/EAN number as a string if visible, or null\n'
    '- "sku": the SKU code as a string if visible, or null\n'
    '- "category": product category (e.g. "Snacks", "Beverages", "Dairy")\n'
    '- "quantity": how many units of this specific product are visible (integer)\n'
    '- "confidence": your confidence in the identification (0.0 to 1.0)\n'
    '- "ocr_text": any text you can read on the packaging, or null\n'
    '- "description": brief physical description of the product\n\n'
    "Return valid JSON with an \"items\" array containing all detected products.\n"
    "If you cannot confidently identify a product, still include it with low "
    "confidence and whatever partial information you extracted.\n"
    "Do not fabricate barcodes or SKUs — only include them if clearly visible.\n"
    "If the image does not contain recognizable retail products, return "
    "{\"items\": []}."
)

USER_PROMPT = "Analyze this image for retail products. Return a JSON array of all detected products."

# Regex to extract JSON from markdown code fences or raw text
_JSON_FENCE_RE = re.compile(r"```(?:json)?\s*(\{.*?\})\s*```", re.DOTALL)


@runtime_checkable
class VisionProvider(Protocol):
    """Minimal async provider interface for external vision APIs."""

    async def analyze(self, image_b64: str, mime_type: str) -> str:
        """Send image to the provider; return raw response text (JSON string)."""
        ...


class OpenAIVisionProvider:
    """OpenAI GPT-4o / GPT-4o-mini vision (ChatCompletions API)."""

    def __init__(self, api_key: str, model: str = "gpt-4o-mini") -> None:
        self._api_key = api_key
        self._model = model

    async def analyze(self, image_b64: str, mime_type: str) -> str:
        url = "https://api.openai.com/v1/chat/completions"
        headers = {
            "Authorization": f"Bearer {self._api_key}",
            "Content-Type": "application/json",
        }
        body = {
            "model": self._model,
            "messages": [
                {"role": "system", "content": SYSTEM_PROMPT},
                {
                    "role": "user",
                    "content": [
                        {
                            "type": "image_url",
                            "image_url": {
                                "url": f"data:{mime_type};base64,{image_b64}",
                                "detail": "high",
                            },
                        },
                        {"type": "text", "text": USER_PROMPT},
                    ],
                },
            ],
            "response_format": {"type": "json_object"},
            "max_tokens": 2000,
            "temperature": 0.1,
        }
        settings = get_settings()
        timeout = httpx.Timeout(settings.ai_vision_timeout)
        async with httpx.AsyncClient(timeout=timeout) as client:
            resp = await client.post(url, headers=headers, json=body)
            resp.raise_for_status()
            data = resp.json()
            return data["choices"][0]["message"]["content"]


class GoogleVisionProvider:
    """Google Gemini 1.5 Flash / Pro (generateContent API)."""

    def __init__(self, api_key: str, model: str = "gemini-1.5-flash") -> None:
        self._api_key = api_key
        self._model = model

    async def analyze(self, image_b64: str, mime_type: str) -> str:
        url = (
            f"https://generativelanguage.googleapis.com/v1beta/models/"
            f"{self._model}:generateContent?key={self._api_key}"
        )
        body = {
            "contents": [
                {
                    "parts": [
                        {
                            "inline_data": {
                                "mime_type": mime_type,
                                "data": image_b64,
                            }
                        },
                        {"text": f"{SYSTEM_PROMPT}\n\n{USER_PROMPT}"},
                    ]
                }
            ],
            "generationConfig": {
                "responseMimeType": "application/json",
                "temperature": 0.1,
                "maxOutputTokens": 2000,
            },
        }
        settings = get_settings()
        timeout = httpx.Timeout(settings.ai_vision_timeout)
        async with httpx.AsyncClient(timeout=timeout) as client:
            resp = await client.post(url, json=body)
            resp.raise_for_status()
            data = resp.json()
            return data["candidates"][0]["content"]["parts"][0]["text"]


_PROVIDER_REGISTRY: dict[str, type[OpenAIVisionProvider | GoogleVisionProvider]] = {
    "openai": OpenAIVisionProvider,
    "google": GoogleVisionProvider,
}


def _build_provider() -> VisionProvider | None:
    """Build the configured provider, or None for mock fallback."""
    settings = get_settings()
    name = settings.ai_vision_provider.lower().strip()
    key = settings.ai_vision_api_key.strip()
    if not name or name not in _PROVIDER_REGISTRY:
        return None
    if not key:
        logger.warning(
            "ai_vision_provider=%s configured but ai_vision_api_key is empty; "
            "falling back to mock adapter",
            name,
        )
        return None
    model = settings.ai_vision_model.strip() or None
    if name == "openai":
        return OpenAIVisionProvider(api_key=key, model=model or "gpt-4o-mini")
    if name == "google":
        return GoogleVisionProvider(api_key=key, model=model or "gemini-1.5-flash")
    return None  # pragma: no cover


# ---------------------------------------------------------------------------
# Response parser
# ---------------------------------------------------------------------------


def _safe_decimal(value: str | float | None, default: str = "0") -> Decimal:
    """Best-effort Decimal conversion; returns default on failure."""
    if value is None:
        return Decimal(default)
    try:
        return Decimal(str(value))
    except (ValueError, TypeError):
        return Decimal(default)


def _parse_items(raw: str) -> list[DetectedItem]:
    """Parse the provider JSON response into DetectedItems.

    Handles markdown-fenced JSON, partial responses, and malformed entries
    gracefully — unparseable entries are skipped rather than failing the
    entire scan.
    """
    text = raw.strip()
    # Strip markdown code fences if present
    fence_match = _JSON_FENCE_RE.search(text)
    if fence_match:
        text = fence_match.group(1).strip()
    else:
        # Try to find raw JSON object in the response
        brace_start = text.find("{")
        brace_end = text.rfind("}")
        if brace_start != -1 and brace_end > brace_start:
            text = text[brace_start : brace_end + 1]

    try:
        data = json.loads(text)
    except json.JSONDecodeError as exc:
        logger.warning("Failed to parse provider response as JSON: %s", exc)
        return []

    items_raw = data if isinstance(data, list) else data.get("items", [])
    if not isinstance(items_raw, list):
        return []

    results: list[DetectedItem] = []
    for entry in items_raw:
        if not isinstance(entry, dict):
            continue
        try:
            conf = _safe_decimal(entry.get("confidence"), "0.5")
            qty = _safe_decimal(entry.get("quantity"), "1")
            if qty <= 0:
                qty = Decimal(1)
            meta: dict = {}
            for key in ("name", "brand", "category", "ocr_text", "description"):
                val = entry.get(key)
                if val is not None and str(val).strip():
                    meta[key] = str(val).strip()
            results.append(
                DetectedItem(
                    method="visual",
                    detected_sku=entry.get("sku") or None,
                    detected_barcode=entry.get("barcode") or None,
                    confidence=conf,
                    quantity=qty,
                    meta=meta or None,
                )
            )
        except (ValueError, TypeError, KeyError, AttributeError) as exc:
            logger.debug("Skipping unparseable detection entry: %s", exc)
    return results


# ---------------------------------------------------------------------------
# RealAIVisionPort — the M4-B adapter
# ---------------------------------------------------------------------------


class RealAIVisionPort:
    """External API-based `AIVisionPort` implementation.

    Provider is selected once at init via environment config. If the provider
    is unavailable or misconfigured, the composition root falls back to the
    mock adapter (see `app/ai/__init__.py`).
    """

    def __init__(self, provider: VisionProvider) -> None:
        self._provider = provider

    async def analyze_image(self, image: bytes, context: VisionContext) -> list[DetectedItem]:
        if not image:
            return []
        mime = _detect_mime(image)
        image_b64 = base64.b64encode(image).decode("ascii")
        try:
            raw_response = await self._provider.analyze(image_b64, mime)
        except httpx.TimeoutException:
            raise
        except httpx.HTTPStatusError as exc:
            logger.error(
                "Vision provider HTTP error %s: %s",
                exc.response.status_code,
                exc.response.text[:200] if exc.response.text else "",
            )
            raise
        except Exception:
            logger.exception("Vision provider call failed")
            raise
        items = _parse_items(raw_response)
        logger.info("Vision adapter returned %d detection(s)", len(items))
        return items
