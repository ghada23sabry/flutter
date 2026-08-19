"""The vision adapter contract.

Business/service layers depend on this protocol, never on a concrete
implementation, so swapping the deterministic mock for a real inference adapter
(M4-B) requires no business-layer changes.
"""
from typing import Protocol, runtime_checkable

from app.ai.contract import DetectedItem, VisionContext


@runtime_checkable
class AIVisionPort(Protocol):
    """Analyses one scan image and returns typed detections.

    Pure function of its inputs: no session, no database, no inventory access.
    `image` is the raw captured image bytes (the mock defines its own
    deterministic byte contract; the real adapter will parse real images).
    """

    async def analyze_image(self, image: bytes, context: VisionContext) -> list[DetectedItem]: ...
