from sqlalchemy import text

from app.core.db import engine


async def test_database_connectivity():
    async with engine.connect() as conn:
        result = await conn.execute(text("SELECT 1"))
        assert result.scalar_one() == 1
