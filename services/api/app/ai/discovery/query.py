"""Query normalization: model number detection, domain classification, search building."""
from __future__ import annotations

import re
from dataclasses import dataclass

# ── Model / Part Number Patterns ────────────────────────────────────────────

# Samsung: SM-A556E, SM-G991B
_RE_SAMSUNG_MODEL = re.compile(r"\b(SM-[A-Z]\d{3,4}[A-Z]?)\b", re.IGNORECASE)

# Generic alphanumeric model: 2+ uppercase letters/digits, optional dash/space+alphanum
_RE_GENERIC_MODEL = re.compile(
    r"\b([A-Z]{1,4}[-\s]?\d{2,6}[A-Z]{0,4})\b"
)

# Bosch-style: GSB 13 RE, GWS 18-10
_RE_BOSCH_MODEL = re.compile(
    r"\b([A-Z]{2,4}\s+\d{1,3}(?:\s*[-/]\s*\d{1,3})?(?:\s+[A-Z]{1,4})?)\b"
)

# Part / SKU: starts with # or ends with -NNN pattern
_RE_PART_NUMBER = re.compile(
    r"\b(?:P/N|Part\s*#?|SKU[:\s]*)\s*([A-Z0-9][-A-Z0-9]{3,20})\b",
    re.IGNORECASE,
)

# Serial / Product code: long alphanumeric with dashes
_RE_SERIAL = re.compile(
    r"\b([A-Z0-9]{2,4}[-][A-Z0-9]{2,8}[-][A-Z0-9]{2,8})\b"
)

# EAN/UPC barcode (12-13 digits)
_RE_BARCODE = re.compile(r"\b(\d{8,14})\b")


@dataclass
class NormalizedQuery:
    """Structured extraction from raw OCR/product text."""

    brand: str | None = None
    model_number: str | None = None
    part_number: str | None = None
    product_name: str | None = None
    category_hint: str | None = None
    raw_text: str = ""
    domain: str = "unknown"  # food, beauty, electronics, tools, household, unknown


def normalize_query(
    *,
    name: str | None = None,
    brand: str | None = None,
    barcode: str | None = None,
    category: str | None = None,
    ocr_text: str | None = None,
    variant: str | None = None,
    model_name: str | None = None,
) -> NormalizedQuery:
    """Extract structured fields from raw product detection data.

    Prioritises model numbers and brand+model over generic text searches.
    """
    raw_parts = [ocr_text, name, brand, model_name, variant, category]
    raw_text = " ".join(p for p in raw_parts if p).strip()

    model = _extract_model_number(raw_text, model_name)
    part = _extract_part_number(raw_text)
    detected_brand = brand or _guess_brand_from_text(raw_text)
    domain = classify_domain(raw_text, category)

    return NormalizedQuery(
        brand=detected_brand,
        model_number=model,
        part_number=part,
        product_name=name,
        category_hint=category,
        raw_text=raw_text,
        domain=domain,
    )


def _extract_model_number(text: str, explicit_model: str | None = None) -> str | None:
    """Extract the most likely model number from text."""
    if explicit_model and explicit_model.strip():
        return explicit_model.strip()

    for pattern in [_RE_SAMSUNG_MODEL, _RE_BOSCH_MODEL, _RE_PART_NUMBER, _RE_GENERIC_MODEL]:
        m = pattern.search(text)
        if m:
            return m.group(1).strip()

    m = _RE_SERIAL.search(text)
    if m:
        return m.group(1).strip()

    return None


def _extract_part_number(text: str) -> str | None:
    m = _RE_PART_NUMBER.search(text)
    return m.group(1).strip() if m else None


def _guess_brand_from_text(text: str) -> str | None:
    """Try to extract a brand from common patterns in OCR text."""
    lower = text.lower()
    known_brands = [
        "samsung", "apple", "sony", "philips", "bosch", "lg", "panasonic",
        "tesla", "toyota", "nike", "adidas", "dell", "hp", "lenovo", "asus",
        "coca-cola", "pepsi", "nestle", "unilever", "p&g", "procter",
        "gillette", "nivea", "dove", "loreal", "olay", "colgate",
        "makita", "hitachi", "siemens", "whirlpool", "haier",
        "midea", "dyson", "ikea", "3m", "honda", "yamaha",
        "intel", "amd", "nvidia", "corsair", "logitech", "razer",
        "xiaomi", "huawei", "oppo", "vivo", "realme", "oneplus",
        "toshiba", "fujitsu", "compaq", "gateway", "acer",
        "canon", "nikon", "gopro", "gopro", "fujifilm", "olympus",
        "jbl", "bose", "sennheiser", "beats", "skullcandy",
        "benq", "viewsonic", "wacom", "logitech",
        "black+decker", "black and decker", "ryobi", "milwaukee",
        "dewalt", "craftsman", "stanley", "hilti", "festool",
        "karcher", "hoover", "dirt devil", "shark", "irobot",
        "kitchenaid", "cuisinart", "ninja", "instant pot",
        "noritex", "ralphs", "target", "walmart", "costco",
        "amd", "arm", "qualcomm", "mediatek", "broadcom",
        "kingston", "crucial", "samsung memory", "western digital", "wd",
        "seagate", "sandisk", "kingston",
        "asus", "msi", "gigabyte", "evga", "zotac",
        "thermaltake", "coolermaster", "corsair", "nzxt", "fractal",
    ]
    for brand in known_brands:
        if brand in lower:
            return brand.title().replace("-", "-").replace("&", "&")
    words = text.split()
    if words:
        first = words[0].strip("#:-")
        if first and first[0].isupper() and len(first) >= 2:
            return first
    return None


# ── Domain Classification ──────────────────────────────────────────────────

_FOOD_KEYWORDS = {
    "food", "beverage", "drink", "snack", "candy", "chocolate", "bread",
    "milk", "cheese", "yogurt", "juice", "water", "soda", "beer", "wine",
    "coffee", "tea", "rice", "pasta", "sauce", "oil", "vinegar", "spice",
    "cereal", "cookie", "biscuit", "nut", "fruit", "vegetable", "meat",
    "fish", "seafood", "frozen", "canned", "organic", "nutrition",
    "calorie", "protein", "carb", "sugar", "salt", "fat", "vitamin",
}

_BEAUTY_KEYWORDS = {
    "shampoo", "conditioner", "soap", "body wash", "lotion", "moisturizer",
    "cream", "serum", "sunscreen", "spf", "deodorant", "perfume",
    "fragrance", "makeup", "lipstick", "mascara", "foundation", "blush",
    "skincare", "facial", "cleanser", "toner", "mask", "scrub",
    "toothpaste", "toothbrush", "mouthwash", "dental", "hair", "nail",
    "cosmetic", "beauty", "personal care", "hygiene", "moisturizing",
    "anti-aging", "retinol", "hyaluronic", "vitamin c serum",
}

_ELECTRONICS_KEYWORDS = {
    "phone", "smartphone", "tablet", "laptop", "computer", "monitor",
    "tv", "television", "camera", "headphone", "earbuds", "speaker",
    "charger", "cable", "adapter", "battery", "ssd", "hdd", "ram",
    "cpu", "gpu", "motherboard", "router", "modem", "keyboard", "mouse",
    "printer", "scanner", "projector", "display", "led", "lcd", "oled",
    "smart watch", "fitness tracker", "power bank", "usb", "bluetooth",
    "wifi", "ethernet", "hdmi", "microsd", "flash drive", "storage",
    "processor", "graphics", "memory", "chipset", "gaming", "console",
    "playstation", "xbox", "nintendo", "galaxy", "iphone", "ipad",
    "macbook", "thinkpad", "surface", "pixel", "airpods", "beats",
    "xiaomi", "huawei", "oneplus", "oppo", "vivo",
    "cellphone", "mobile", "handset",
    "webcam", "microphone", "headset", "earphone", "earpiece",
    "harddisk", "hard disk", "flashdisk", "pendrive", "memory card",
    "ups", "inverter", "solar panel", "electrical",
    "sensor", "barcode scanner", "pos terminal", "receipt printer",
    "cash register", "scale", "weighing",
}

_TOOLS_KEYWORDS = {
    "drill", "saw", "sander", "grinder", "wrench", "screwdriver",
    "plier", "hammer", "tool", "workshop", "power tool", "cordless",
    "lithium", "torque", "rpm", "voltage", "volt", "ampere", "watt",
    "tool box", "toolbox", "measuring", "level", "tape measure",
    "bosch", "makita", "dewalt", "milwaukee", "craftsman", "stanley",
    "hilti", "ryobi", "black+decker", "black and decker",
    "impact driver", "impact wrench", "jigsaw", "circular saw",
    "reciprocating saw", "angle grinder", "bench grinder",
    "rotary tool", "multitool", "oscillating",
    "clamp", "vise", "chisel", "file", "rasp",
    "socket", "ratchet", "torque wrench", "hex key", "allen key",
    "drill bit", "saw blade", "sanding disc", "grinding wheel",
    "wire stripper", "crimping tool", "multimeter", "test meter",
}

_HOUSEHOLD_KEYWORDS = {
    "cleaner", "detergent", "bleach", "disinfectant", "sanitizer",
    "mop", "broom", "vacuum", "air purifier", "humidifier",
    "iron", "steamer", "blender", "mixer", "toaster", "microwave",
    "oven", "refrigerator", "freezer", "dishwasher", "washer", "dryer",
    "kitchen", "appliance", "home", "household", "cleaning",
    "garbage", "trash", "bin", "recycle",
    "air conditioner", "ac unit", "heater", "fan",
    "water heater", "boiler",
    "cookware", "frying pan", "saucepan", "pot", "wok",
    "knife", "cutting board", "utensil", "spatula", "ladle",
    "food processor", "juicer", "kettle", "coffee maker",
    "rice cooker", "slow cooker", "pressure cooker", "airfryer",
    "mattress", "pillow", "blanket", "towel", "curtain",
    "lamp", "light bulb", "led bulb", "fluorescent",
}


def classify_domain(text: str, category_hint: str | None = None) -> str:
    """Classify product text into a domain category.

    Uses keyword scoring with a low threshold for electronics/tools/household
    since brand names and model numbers alone often identify the domain.
    """
    combined = f"{text} {category_hint or ''}".lower()

    scores = {
        "food": sum(1 for kw in _FOOD_KEYWORDS if kw in combined),
        "beauty": sum(1 for kw in _BEAUTY_KEYWORDS if kw in combined),
        "electronics": sum(1 for kw in _ELECTRONICS_KEYWORDS if kw in combined),
        "tools": sum(1 for kw in _TOOLS_KEYWORDS if kw in combined),
        "household": sum(1 for kw in _HOUSEHOLD_KEYWORDS if kw in combined),
    }

    best = max(scores, key=scores.get)  # type: ignore[arg-type]
    best_score = scores[best]

    # Single keyword match is enough for any domain
    if best_score >= 1:
        return best

    return "unknown"
