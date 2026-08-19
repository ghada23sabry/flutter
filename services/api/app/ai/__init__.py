"""Composition root for the vision adapter.

Services depend on the `AIVisionPort` protocol; this factory is the only place
that names the concrete adapter. M4-B swaps in the real adapter when
`AI_VISION_PROVIDER` and `AI_VISION_API_KEY` are configured; otherwise the
deterministic mock is used for backward compatibility.
"""
from app.ai.vision_port import AIVisionPort


def get_vision_port() -> AIVisionPort:
    from app.ai.real_vision import RealAIVisionPort, _build_provider

    provider = _build_provider()
    if provider is not None:
        return RealAIVisionPort(provider)

    from app.ai.mock_vision import MockAIVisionPort

    return MockAIVisionPort()
