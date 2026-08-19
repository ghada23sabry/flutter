"""Direct Gemini 3.6 Flash image test — Phase 3.

Tests the actual Gemini response structure with a real image to verify
whether parts[0]["text"] extraction works or if Gemini 3.6 returns
thought parts first.
"""
import asyncio
import base64
import json
import httpx
import sys


async def test():
    # Read config from .env
    settings = {}
    with open(".env") as f:
        for line in f:
            line = line.strip()
            if "=" in line and not line.startswith("#"):
                k, v = line.split("=", 1)
                settings[k.strip()] = v.strip()

    api_key = settings.get("AI_VISION_API_KEY", "")
    model = settings.get("AI_VISION_MODEL", "gemini-3.6-flash")
    timeout_s = float(settings.get("AI_VISION_TIMEOUT", "30"))

    if not api_key:
        print("ERROR: No API key configured")
        return 1

    print(f"Model: {model}")
    print(f"Timeout: {timeout_s}s")

    # Load real image
    image_path = "C:/Users/PC/Documents/Default Project/test_product.jpg"
    try:
        with open(image_path, "rb") as f:
            image = f.read()
    except FileNotFoundError:
        print(f"ERROR: Image not found at {image_path}")
        return 1

    print(f"Image size: {len(image)} bytes")

    # Detect MIME
    if image[:4] == b"\x89PNG":
        mime = "image/png"
    elif image[:3] == b"\xff\xd8\xff":
        mime = "image/jpeg"
    elif image[:4] == b"RIFF" and image[8:12] == b"WEBP":
        mime = "image/webp"
    else:
        mime = "image/png"
    print(f"Detected MIME: {mime}")

    b64 = base64.b64encode(image).decode("ascii")
    print(f"Base64 size: {len(b64)} chars")

    url = (
        f"https://generativelanguage.googleapis.com/v1beta/models/"
        f"{model}:generateContent?key={api_key}"
    )
    body = {
        "contents": [
            {
                "parts": [
                    {
                        "inline_data": {
                            "mime_type": mime,
                            "data": b64,
                        }
                    },
                    {
                        "text": (
                            "Analyze this image for retail products. "
                            "Return valid JSON with an 'items' array. "
                            "Each item must have: name, quantity, confidence."
                        )
                    },
                ]
            }
        ],
        "generationConfig": {
            "temperature": 0.1,
            "maxOutputTokens": 2000,
        },
    }

    print(f"\nSending to {model}...")
    try:
        async with httpx.AsyncClient(timeout=httpx.Timeout(timeout_s)) as client:
            resp = await client.post(url, json=body)
    except httpx.TimeoutException:
        print("TIMEOUT after {timeout_s}s")
        return 1
    except Exception as e:
        print(f"HTTP ERROR: {type(e).__name__}: {e}")
        return 1

    print(f"HTTP status: {resp.status_code}")

    if resp.status_code != 200:
        print(f"Error body: {resp.text[:500]}")
        return 1

    data = resp.json()
    print(f"\nResponse top-level keys: {list(data.keys())}")

    # Show full structure for debugging
    candidates = data.get("candidates", [])
    print(f"Candidates count: {len(candidates)}")

    if not candidates:
        print("ERROR: No candidates in response")
        print(f"Full response: {json.dumps(data, indent=2)[:2000]}")
        return 1

    for i, c in enumerate(candidates):
        print(f"\nCandidate {i}:")
        print(f"  Keys: {list(c.keys())}")
        if "finishReason" in c:
            print(f"  finishReason: {c['finishReason']}")
        content = c.get("content", {})
        print(f"  content keys: {list(content.keys())}")
        parts = content.get("parts", [])
        print(f"  parts count: {len(parts)}")
        for j, p in enumerate(parts):
            keys = list(p.keys())
            print(f"  part {j} keys: {keys}")
            if "thought" in p:
                print(f"  part {j} thought: {p['thought']}")
            if "text" in p:
                txt = p["text"]
                print(f"  part {j} text (first 300): {txt[:300]}")
            if "thoughtSignature" in str(p):
                print(f"  part {j} HAS thoughtSignature")

    # Now test the exact extraction path from real_vision.py
    print("\n=== Testing real_vision.py extraction path ===")
    try:
        text = data["candidates"][0]["content"]["parts"][0]["text"]
        print(f"SUCCESS: parts[0]['text'] extracted")
        print(f"Text (first 500): {text[:500]}")
    except (KeyError, IndexError, TypeError) as e:
        print(f"FAILED: {type(e).__name__}: {e}")
        # Try to find the text part
        print("Attempting to find text part...")
        for pi, p in enumerate(parts):
            if "text" in p and not p.get("thought", False):
                text = p["text"]
                print(f"Found text in part {pi}: {text[:500]}")
                break
        else:
            print("No text part found!")
        return 1

    # Test JSON parsing
    print("\n=== Testing JSON parsing ===")
    try:
        parsed = json.loads(text)
        print(f"JSON parsed: {type(parsed).__name__}")
        items = parsed if isinstance(parsed, list) else parsed.get("items", [])
        print(f"Items count: {len(items)}")
        for item in items[:3]:
            print(f"  Item: {json.dumps(item, indent=2)[:200]}")
    except json.JSONDecodeError as e:
        print(f"JSON parse failed: {e}")
        print(f"Raw text: {text[:500]}")

    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(test()))
