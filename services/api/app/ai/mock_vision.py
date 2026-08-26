"""Deterministic mock `AIVisionPort` for M4-A end-to-end development.

Byte contract (documented, reproducible):
    image = <valid JPEG header> + b"VS-MOCK-1\n" + <JSON of MockImagePayload>

`encode_mock_image()` produces valid JPEG images from a typed payload. Any input
that does not match the contract (empty bytes, non-UTF-8, wrong magic, malformed
or invalid items) deterministically yields the fallback below — a single low-score,
unmatched visual detection. The confidence/needs-review gate itself is the service
layer's decision (M4-A.3), so the mock never decides product identity and never
touches inventory.
"""
import io
import json
from decimal import Decimal

from PIL import Image
from pydantic import BaseModel

from app.ai.contract import DetectedItem, VisionContext

MAGIC = "VS-MOCK-1"

FALLBACK_CONFIDENCE = Decimal("0.40")
FALLBACK_QUANTITY = Decimal(1)

# Minimal 1x1 white JPEG used as a valid image prefix so MIME validation passes.
_MINIMAL_JPEG = Image.new("RGB", (1, 1), "white")
_buf = io.BytesIO()
_MINIMAL_JPEG.save(_buf, format="JPEG")
_JPEG_HEADER = _buf.getvalue()
_MINIMAL_JPEG.close()
_BUF_SIZE = len(_JPEG_HEADER)


class MockImagePayload(BaseModel):
    """Typed payload embedded in a mock image. Items are returned in order."""

    items: list[DetectedItem]


def encode_mock_image(payload: MockImagePayload) -> bytes:
    """Encode a typed payload into a valid JPEG image byte string.

    The output starts with a real JPEG header (passes MIME validation),
    followed by the VS-MOCK payload marker and JSON data.
    """
    payload_bytes = f"{MAGIC}\n{payload.model_dump_json()}".encode()
    return _JPEG_HEADER + payload_bytes


def _decode_mock_image(data: bytes) -> str | None:
    """Extract the VS-MOCK payload from image bytes.

    Returns the JSON portion of the payload, or None if not a mock image.
    Works with both raw mock bytes and JPEG-prefixed mock bytes.
    """
    marker = f"{MAGIC}\n".encode()
    idx = data.find(marker)
    if idx < 0:
        return None
    payload = data[idx + len(marker) :]
    try:
        return payload.decode("utf-8")
    except UnicodeDecodeError:
        return None


class MockAIVisionPort:
    """Deterministic adapter: same bytes → same detections, always."""

    async def analyze_image(self, image: bytes, context: VisionContext) -> list[DetectedItem]:
        json_str = _decode_mock_image(image)
        if json_str is None:
            return [self._fallback_item()]
        try:
            data = json.loads(json_str)
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
