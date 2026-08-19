"""Deterministic mock `AIVisionPort` for M4-A end-to-end development.

Byte contract (documented, reproducible):
    image = b"VS-MOCK-1\\n" + <JSON of MockImagePayload>

`encode_mock_image()` produces valid images from a typed payload. Any input that
does not match the contract (empty bytes, non-UTF-8, wrong magic, malformed or
invalid items) deterministically yields the fallback below — a single low-score,
unmatched visual detection. The confidence/needs-review gate itself is the
service layer's decision (M4-A.3), so the mock never decides product identity
and never touches inventory.
"""
import json
from decimal import Decimal

from pydantic import BaseModel

from app.ai.contract import DetectedItem, VisionContext

MAGIC = "VS-MOCK-1"

FALLBACK_CONFIDENCE = Decimal("0.40")
FALLBACK_QUANTITY = Decimal(1)


class MockImagePayload(BaseModel):
    """Typed payload embedded in a mock image. Items are returned in order."""

    items: list[DetectedItem]


def encode_mock_image(payload: MockImagePayload) -> bytes:
    """Encode a typed payload into a valid mock image byte string."""
    return f"{MAGIC}\n{payload.model_dump_json()}".encode()


class MockAIVisionPort:
    """Deterministic adapter: same bytes → same detections, always."""

    async def analyze_image(self, image: bytes, context: VisionContext) -> list[DetectedItem]:
        try:
            text = image.decode("utf-8")
        except UnicodeDecodeError:
            return [self._fallback_item()]
        if not text.startswith(f"{MAGIC}\n"):
            return [self._fallback_item()]
        try:
            data = json.loads(text.split("\n", 1)[1])
            items = [DetectedItem.model_validate(item) for item in data["items"]]
        except (ValueError, KeyError, TypeError, json.JSONDecodeError):
            return [self._fallback_item()]
        return items

    @staticmethod
    def _fallback_item() -> DetectedItem:
        return DetectedItem(
            method="visual",
            confidence=FALLBACK_CONFIDENCE,
            quantity=FALLBACK_QUANTITY,
        )
