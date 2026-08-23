"""product recognition memory — barcode→product mapping confirmed through AI scan workflow

Stores confirmed barcode-to-product mappings scoped to (tenant, store).
Written on confirmation (confirm_scan_session or link_detection_to_product).
Used as a fast lookup in _resolve_product before falling back to name matching.

Revision ID: 0009
Revises: 0008
Create Date: 2026-08-23

"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "0009"
down_revision: str | None = "0008"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "product_recognitions",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column(
            "tenant_id",
            sa.Uuid(),
            sa.ForeignKey("tenants.id", ondelete="CASCADE"),
            nullable=False,
            index=True,
        ),
        sa.Column(
            "store_id",
            sa.Uuid(),
            sa.ForeignKey("stores.id", ondelete="CASCADE"),
            nullable=False,
            index=True,
        ),
        sa.Column("barcode", sa.String(length=64), nullable=False),
        sa.Column(
            "product_id",
            sa.Uuid(),
            sa.ForeignKey("products.id", ondelete="CASCADE"),
            nullable=False,
            index=True,
        ),
        sa.Column(
            "source", sa.String(length=30), server_default="user_confirm", nullable=False
        ),
        sa.Column("hit_count", sa.Integer(), server_default="1", nullable=False),
        sa.Column(
            "created_by",
            sa.Uuid(),
            sa.ForeignKey("users.id", ondelete="SET NULL"),
            nullable=True,
            index=True,
        ),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.func.now(),
            nullable=False,
        ),
        sa.Column(
            "updated_at",
            sa.DateTime(timezone=True),
            server_default=sa.func.now(),
            nullable=False,
        ),
        sa.UniqueConstraint(
            "tenant_id", "store_id", "barcode",
            name="uq_product_recognitions_tenant_store_barcode",
        ),
    )
    op.create_index(
        "ix_product_recognitions_tenant_store",
        "product_recognitions",
        ["tenant_id", "store_id"],
    )
    op.create_index(
        "ix_product_recognitions_barcode",
        "product_recognitions",
        ["barcode"],
    )


def downgrade() -> None:
    op.drop_index("ix_product_recognitions_barcode", table_name="product_recognitions")
    op.drop_index("ix_product_recognitions_tenant_store", table_name="product_recognitions")
    op.drop_table("product_recognitions")
