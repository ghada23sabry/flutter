"""structural guard: at most one COUNT movement per (store, product, scan session)

M4-A.4: confirmation already serializes on the scan session row, but this
partial unique index makes "no duplicate movement" a database invariant. It only
constrains COUNT movements referencing a SCAN_SESSION, so existing OPENING /
ADJUSTMENT / EXPIRY_BATCH movements (all reference_type NULL or EXPIRY_BATCH)
are untouched and M1–M3 concurrency semantics are preserved.

Revision ID: 0007
Revises: 0006
Create Date: 2026-08-13

"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "0007"
down_revision: str | None = "0006"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_index(
        "uq_stock_movements_scan_count",
        "stock_movements",
        ["store_id", "product_id", "reference_id"],
        unique=True,
        postgresql_where=sa.text("movement_type = 'COUNT' AND reference_type = 'SCAN_SESSION'"),
    )


def downgrade() -> None:
    op.drop_index("uq_stock_movements_scan_count", table_name="stock_movements")
