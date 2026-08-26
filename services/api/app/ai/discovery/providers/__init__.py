"""Discovery providers package."""
from app.ai.discovery.providers.general_product import search_general_products
from app.ai.discovery.providers.open_beauty_facts import search_open_beauty_facts
from app.ai.discovery.providers.open_food_facts import search_open_food_facts

__all__ = [
    "search_general_products",
    "search_open_beauty_facts",
    "search_open_food_facts",
]
