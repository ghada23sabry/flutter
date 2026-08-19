"""scan session operation + scan-movement dedup across all operations

First-release sprint: a scan session now carries a business `operation`
(count | receive | sale) so confirmation can write COUNT / PURCHASE / SALE
movements. The old dedup index only protected COUNT movements; it is widened to
guard every SCAN_SESSION-referenced movement (COUNT, PURCHASE, SALE) so a
duplicate confirmation can never double-apply inventory for any operation. All
existing SCAN_SESSION movements are COUNT, and a session has at most one row
per product, so widening the predicate is safe for existing data.

Revision ID: 0008
Revises: 0007
Create Date: 2026-08-16

"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "0008"
down_revision: str | None = "0007"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column(
        "scan_sessions",
        sa.Column("operation", sa.String(length=10), server_default="count", nullable=False),
    )
    op.create_check_constraint(
        "ck_scan_sessions_operation",
        "scan_sessions",
        "operation IN ('count', 'receive', 'sale')",
    )

    op.drop_index("uq_stock_movements_scan_count", table_name="stock_movements")
    op.create_index(
        "uq_stock_movements_scan_session",
        "stock_movements",
        ["store_id", "product_id", "reference_id"],
        unique=True,
        postgresql_where=sa.text("reference_type = 'SCAN_SESSION'"),
    )


def downgrade() -> None:
    op.drop_index("uq_stock_movements_scan_session", table_name="stock_movements")
    op.create_index(
        "uq_stock_movements_scan_count",
        "stock_movements",
        ["store_id", "product_id", "reference_id"],
        unique=True,
        postgresql_where=sa.text("movement_type = 'COUNT' AND reference_type = 'SCAN_SESSION'"),
    )

    op.drop_constraint("ck_scan_sessions_operation", "scan_sessions", type_="check")
    op.drop_column("scan_sessions", "operation")
