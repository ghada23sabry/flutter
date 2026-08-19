"""AI vision domain schema: scan_sessions, scan_detections, scan_reconciliations

Revision ID: 0005
Revises: 0004
Create Date: 2026-08-13

"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0005"
down_revision: str | None = "0004"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

PERMISSIONS = [
    ("ai.scan", "ai", "Run vision scans and record detections"),
    ("ai.reconcile", "ai", "Review scan reconciliations"),
    ("ai.confirm", "ai", "Confirm reconciliations and apply stock counts"),
    ("ai.view", "ai", "View scan history"),
]

SYSTEM_ROLES = ["owner", "admin"]


def upgrade() -> None:
    op.create_table(
        "scan_sessions",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("tenant_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("tenants.id", ondelete="CASCADE"), nullable=False),
        sa.Column("store_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("stores.id", ondelete="CASCADE"), nullable=False),
        sa.Column("shelf_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("shelves.id", ondelete="SET NULL"), nullable=True),
        sa.Column("status", sa.String(20), nullable=False, server_default="active"),
        sa.Column("note", sa.Text(), nullable=True),
        sa.Column("image_count", sa.Integer(), nullable=False, server_default=sa.text("0")),
        sa.Column("started_by", postgresql.UUID(as_uuid=True), sa.ForeignKey("users.id", ondelete="SET NULL"), nullable=True),
        sa.Column("completed_by", postgresql.UUID(as_uuid=True), sa.ForeignKey("users.id", ondelete="SET NULL"), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("completed_at", sa.DateTime(timezone=True), nullable=True),
        sa.CheckConstraint("image_count >= 0", name="ck_scan_sessions_image_count_nonneg"),
    )
    op.create_index("ix_scan_sessions_tenant_id", "scan_sessions", ["tenant_id"])
    op.create_index("ix_scan_sessions_store_id", "scan_sessions", ["store_id"])
    op.create_index("ix_scan_sessions_store_created", "scan_sessions", ["store_id", "created_at"])
    op.create_index("ix_scan_sessions_store_status", "scan_sessions", ["store_id", "status"])
    op.create_index("ix_scan_sessions_shelf_id", "scan_sessions", ["shelf_id"])
    op.create_index("ix_scan_sessions_started_by", "scan_sessions", ["started_by"])
    op.create_index("ix_scan_sessions_completed_by", "scan_sessions", ["completed_by"])

    op.create_table(
        "scan_detections",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("tenant_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("tenants.id", ondelete="CASCADE"), nullable=False),
        sa.Column("store_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("stores.id", ondelete="CASCADE"), nullable=False),
        sa.Column("session_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("scan_sessions.id", ondelete="CASCADE"), nullable=False),
        sa.Column("image_key", sa.String(255), nullable=True),
        sa.Column("method", sa.String(30), nullable=False),
        sa.Column("detected_sku", sa.String(64), nullable=True),
        sa.Column("detected_barcode", sa.String(64), nullable=True),
        sa.Column("product_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("products.id", ondelete="SET NULL"), nullable=True),
        sa.Column("confidence", sa.Numeric(5, 4), nullable=True),
        sa.Column("quantity_detected", sa.Numeric(12, 3), nullable=False),
        sa.Column("status", sa.String(20), nullable=False, server_default="accepted"),
        sa.Column("meta", postgresql.JSONB(astext_type=sa.Text()), nullable=True),
        sa.Column("created_by", postgresql.UUID(as_uuid=True), sa.ForeignKey("users.id", ondelete="SET NULL"), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.CheckConstraint("quantity_detected > 0", name="ck_scan_detections_quantity_positive"),
        sa.CheckConstraint(
            "confidence IS NULL OR (confidence >= 0 AND confidence <= 1)",
            name="ck_scan_detections_confidence_range",
        ),
    )
    op.create_index("ix_scan_detections_tenant_id", "scan_detections", ["tenant_id"])
    op.create_index("ix_scan_detections_store_id", "scan_detections", ["store_id"])
    op.create_index("ix_scan_detections_store_product", "scan_detections", ["store_id", "product_id"])
    op.create_index("ix_scan_detections_session_id", "scan_detections", ["session_id"])
    op.create_index("ix_scan_detections_product_id", "scan_detections", ["product_id"])
    op.create_index("ix_scan_detections_created_by", "scan_detections", ["created_by"])

    op.create_table(
        "scan_reconciliations",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("tenant_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("tenants.id", ondelete="CASCADE"), nullable=False),
        sa.Column("store_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("stores.id", ondelete="CASCADE"), nullable=False),
        sa.Column("session_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("scan_sessions.id", ondelete="CASCADE"), nullable=False),
        sa.Column("product_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("products.id", ondelete="CASCADE"), nullable=False),
        sa.Column("detected_quantity", sa.Numeric(12, 3), nullable=False),
        sa.Column("system_quantity", sa.Numeric(12, 3), nullable=False),
        sa.Column("variance", sa.Numeric(12, 3), nullable=False),
        sa.Column("status", sa.String(20), nullable=False, server_default="needs_review"),
        sa.Column("resolution", sa.String(20), nullable=True),
        sa.Column("confirmed_by", postgresql.UUID(as_uuid=True), sa.ForeignKey("users.id", ondelete="SET NULL"), nullable=True),
        sa.Column("confirmed_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.UniqueConstraint("session_id", "product_id", name="uq_scan_reconciliations_session_product"),
        sa.CheckConstraint("detected_quantity >= 0", name="ck_scan_reconciliations_detected_nonneg"),
        sa.CheckConstraint("system_quantity >= 0", name="ck_scan_reconciliations_system_nonneg"),
    )
    op.create_index("ix_scan_reconciliations_tenant_id", "scan_reconciliations", ["tenant_id"])
    op.create_index("ix_scan_reconciliations_store_id", "scan_reconciliations", ["store_id"])
    op.create_index("ix_scan_reconciliations_store_product", "scan_reconciliations", ["store_id", "product_id"])
    op.create_index("ix_scan_reconciliations_session_id", "scan_reconciliations", ["session_id"])
    op.create_index("ix_scan_reconciliations_product_id", "scan_reconciliations", ["product_id"])
    op.create_index("ix_scan_reconciliations_confirmed_by", "scan_reconciliations", ["confirmed_by"])

    _seed_ai_permissions()


def _seed_ai_permissions() -> None:
    conn = op.get_bind()
    permission_ids: dict[str, str] = {}
    for code, domain, description in PERMISSIONS:
        row = conn.execute(
            sa.text(
                "INSERT INTO permissions (id, code, domain, description) "
                "VALUES (gen_random_uuid(), :code, :domain, :description) "
                "ON CONFLICT (code) DO NOTHING RETURNING id"
            ),
            {"code": code, "domain": domain, "description": description},
        ).first()
        if row is None:
            row = conn.execute(sa.text("SELECT id FROM permissions WHERE code = :code"), {"code": code}).first()
        permission_ids[code] = row[0]

    for role_name in SYSTEM_ROLES:
        role_id = conn.execute(
            sa.text("SELECT id FROM roles WHERE tenant_id IS NULL AND name = :name"), {"name": role_name}
        ).first()
        if role_id is None:
            continue
        for perm_code in PERMISSIONS:
            conn.execute(
                sa.text(
                    "INSERT INTO role_permissions (role_id, permission_id) "
                    "VALUES (:role_id, :perm_id) "
                    "ON CONFLICT (role_id, permission_id) DO NOTHING"
                ),
                {"role_id": role_id[0], "perm_id": permission_ids[perm_code[0]]},
            )


def downgrade() -> None:
    op.drop_index("ix_scan_reconciliations_confirmed_by", table_name="scan_reconciliations")
    op.drop_index("ix_scan_reconciliations_product_id", table_name="scan_reconciliations")
    op.drop_index("ix_scan_reconciliations_session_id", table_name="scan_reconciliations")
    op.drop_index("ix_scan_reconciliations_store_product", table_name="scan_reconciliations")
    op.drop_index("ix_scan_reconciliations_store_id", table_name="scan_reconciliations")
    op.drop_index("ix_scan_reconciliations_tenant_id", table_name="scan_reconciliations")
    op.drop_table("scan_reconciliations")
    op.drop_index("ix_scan_detections_created_by", table_name="scan_detections")
    op.drop_index("ix_scan_detections_product_id", table_name="scan_detections")
    op.drop_index("ix_scan_detections_session_id", table_name="scan_detections")
    op.drop_index("ix_scan_detections_store_product", table_name="scan_detections")
    op.drop_index("ix_scan_detections_store_id", table_name="scan_detections")
    op.drop_index("ix_scan_detections_tenant_id", table_name="scan_detections")
    op.drop_table("scan_detections")
    op.drop_index("ix_scan_sessions_completed_by", table_name="scan_sessions")
    op.drop_index("ix_scan_sessions_started_by", table_name="scan_sessions")
    op.drop_index("ix_scan_sessions_shelf_id", table_name="scan_sessions")
    op.drop_index("ix_scan_sessions_store_status", table_name="scan_sessions")
    op.drop_index("ix_scan_sessions_store_created", table_name="scan_sessions")
    op.drop_index("ix_scan_sessions_store_id", table_name="scan_sessions")
    op.drop_index("ix_scan_sessions_tenant_id", table_name="scan_sessions")
    op.drop_table("scan_sessions")

    conn = op.get_bind()
    for code, _, _ in PERMISSIONS:
        conn.execute(
            sa.text("DELETE FROM role_permissions WHERE permission_id = (SELECT id FROM permissions WHERE code = :code)"),
            {"code": code},
        )
        conn.execute(sa.text("DELETE FROM permissions WHERE code = :code"), {"code": code})
