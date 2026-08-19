"""inventory + layout schema: zones, shelves, shelf_product_map, inventory, stock_movements, expiry_batches

Revision ID: 0004
Revises: 0003
Create Date: 2026-08-11

"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0004"
down_revision: str | None = "0003"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

PERMISSIONS = [
    ("inventory.view", "inventory", "View inventory balances and stock status"),
    ("inventory.adjust", "inventory", "Set opening stock and apply stock adjustments"),
    ("inventory.manage_layout", "inventory", "Create and manage zones, shelves and shelf mappings"),
    ("inventory.view_movements", "inventory", "View stock movement history"),
    ("inventory.manage_expiry", "inventory", "Create and manage expiry batches"),
]

SYSTEM_ROLES = ["owner", "admin"]


def upgrade() -> None:
    op.create_table(
        "zones",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("tenant_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("tenants.id", ondelete="CASCADE"), nullable=False),
        sa.Column("store_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("stores.id", ondelete="CASCADE"), nullable=False),
        sa.Column("name", sa.String(120), nullable=False),
        sa.Column("code", sa.String(40), nullable=True),
        sa.Column("status", sa.String(20), nullable=False, server_default="active"),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.UniqueConstraint("store_id", "code", name="uq_zones_store_code"),
    )
    op.create_index("ix_zones_tenant_id", "zones", ["tenant_id"])
    op.create_index("ix_zones_store_id", "zones", ["store_id"])
    op.create_index("ix_zones_store_name", "zones", ["store_id", "name"])

    op.create_table(
        "shelves",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("tenant_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("tenants.id", ondelete="CASCADE"), nullable=False),
        sa.Column("store_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("stores.id", ondelete="CASCADE"), nullable=False),
        sa.Column("zone_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("zones.id", ondelete="CASCADE"), nullable=False),
        sa.Column("label", sa.String(120), nullable=False),
        sa.Column("code", sa.String(40), nullable=True),
        sa.Column("position", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("status", sa.String(20), nullable=False, server_default="active"),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.UniqueConstraint("store_id", "code", name="uq_shelves_store_code"),
    )
    op.create_index("ix_shelves_tenant_id", "shelves", ["tenant_id"])
    op.create_index("ix_shelves_store_id", "shelves", ["store_id"])
    op.create_index("ix_shelves_store_zone", "shelves", ["store_id", "zone_id"])
    op.create_index("ix_shelves_zone_id", "shelves", ["zone_id"])

    op.create_table(
        "shelf_product_map",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("tenant_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("tenants.id", ondelete="CASCADE"), nullable=False),
        sa.Column("store_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("stores.id", ondelete="CASCADE"), nullable=False),
        sa.Column("shelf_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("shelves.id", ondelete="CASCADE"), nullable=False),
        sa.Column("product_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("products.id", ondelete="CASCADE"), nullable=False),
        sa.Column("position", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("is_primary", sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.UniqueConstraint("shelf_id", "product_id", name="uq_shelf_product_map"),
    )
    op.create_index("ix_shelf_product_map_tenant_id", "shelf_product_map", ["tenant_id"])
    op.create_index("ix_shelf_product_map_store_id", "shelf_product_map", ["store_id"])
    op.create_index("ix_shelf_product_map_shelf_product", "shelf_product_map", ["shelf_id", "product_id"])
    op.create_index("ix_shelf_product_map_product_id", "shelf_product_map", ["product_id"])

    op.create_table(
        "inventory",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("tenant_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("tenants.id", ondelete="CASCADE"), nullable=False),
        sa.Column("store_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("stores.id", ondelete="CASCADE"), nullable=False),
        sa.Column("product_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("products.id", ondelete="CASCADE"), nullable=False),
        sa.Column("quantity", sa.Numeric(12, 3), nullable=False, server_default=sa.text("0")),
        sa.Column("reserved_quantity", sa.Numeric(12, 3), nullable=False, server_default=sa.text("0")),
        sa.Column("version", sa.Integer(), nullable=False, server_default=sa.text("0")),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.UniqueConstraint("store_id", "product_id", name="uq_inventory_store_product"),
        sa.CheckConstraint("quantity >= 0", name="ck_inventory_quantity_nonneg"),
        sa.CheckConstraint("reserved_quantity >= 0", name="ck_inventory_reserved_nonneg"),
    )
    op.create_index("ix_inventory_tenant_id", "inventory", ["tenant_id"])
    op.create_index("ix_inventory_store_id", "inventory", ["store_id"])
    op.create_index("ix_inventory_product_id", "inventory", ["product_id"])

    op.create_table(
        "stock_movements",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("tenant_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("tenants.id", ondelete="CASCADE"), nullable=False),
        sa.Column("store_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("stores.id", ondelete="CASCADE"), nullable=False),
        sa.Column("product_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("products.id", ondelete="CASCADE"), nullable=False),
        sa.Column("quantity_delta", sa.Numeric(12, 3), nullable=False),
        sa.Column("resulting_quantity", sa.Numeric(12, 3), nullable=True),
        sa.Column("movement_type", sa.String(30), nullable=False),
        sa.Column("reference_type", sa.String(30), nullable=True),
        sa.Column("reference_id", sa.String(64), nullable=True),
        sa.Column("notes", sa.Text(), nullable=True),
        sa.Column("created_by", postgresql.UUID(as_uuid=True), sa.ForeignKey("users.id", ondelete="SET NULL"), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
    )
    op.create_index("ix_stock_movements_tenant_id", "stock_movements", ["tenant_id"])
    op.create_index("ix_stock_movements_store_created", "stock_movements", ["store_id", "created_at"])
    op.create_index("ix_stock_movements_store_product", "stock_movements", ["store_id", "product_id"])
    op.create_index("ix_stock_movements_product_id", "stock_movements", ["product_id"])
    op.create_index("ix_stock_movements_type", "stock_movements", ["movement_type"])
    op.create_index("ix_stock_movements_created_by", "stock_movements", ["created_by"])

    op.create_table(
        "expiry_batches",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("tenant_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("tenants.id", ondelete="CASCADE"), nullable=False),
        sa.Column("store_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("stores.id", ondelete="CASCADE"), nullable=False),
        sa.Column("product_id", postgresql.UUID(as_uuid=True), sa.ForeignKey("products.id", ondelete="CASCADE"), nullable=False),
        sa.Column("batch_code", sa.String(64), nullable=True),
        sa.Column("quantity", sa.Numeric(12, 3), nullable=False, server_default=sa.text("0")),
        sa.Column("expiry_date", sa.Date(), nullable=False),
        sa.Column("received_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.CheckConstraint("quantity >= 0", name="ck_expiry_batches_quantity_nonneg"),
    )
    op.create_index("ix_expiry_batches_tenant_id", "expiry_batches", ["tenant_id"])
    op.create_index("ix_expiry_batches_store_id", "expiry_batches", ["store_id"])
    op.create_index("ix_expiry_batches_store_expiry", "expiry_batches", ["store_id", "expiry_date"])
    op.create_index("ix_expiry_batches_store_product", "expiry_batches", ["store_id", "product_id"])
    op.create_index("ix_expiry_batches_product_id", "expiry_batches", ["product_id"])

    _seed_inventory_permissions()


def _seed_inventory_permissions() -> None:
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
    op.drop_index("ix_expiry_batches_product_id", table_name="expiry_batches")
    op.drop_index("ix_expiry_batches_store_product", table_name="expiry_batches")
    op.drop_index("ix_expiry_batches_store_expiry", table_name="expiry_batches")
    op.drop_index("ix_expiry_batches_store_id", table_name="expiry_batches")
    op.drop_index("ix_expiry_batches_tenant_id", table_name="expiry_batches")
    op.drop_table("expiry_batches")
    op.drop_index("ix_stock_movements_created_by", table_name="stock_movements")
    op.drop_index("ix_stock_movements_type", table_name="stock_movements")
    op.drop_index("ix_stock_movements_product_id", table_name="stock_movements")
    op.drop_index("ix_stock_movements_store_product", table_name="stock_movements")
    op.drop_index("ix_stock_movements_store_created", table_name="stock_movements")
    op.drop_index("ix_stock_movements_tenant_id", table_name="stock_movements")
    op.drop_table("stock_movements")
    op.drop_index("ix_inventory_product_id", table_name="inventory")
    op.drop_index("ix_inventory_store_id", table_name="inventory")
    op.drop_index("ix_inventory_tenant_id", table_name="inventory")
    op.drop_table("inventory")
    op.drop_index("ix_shelf_product_map_product_id", table_name="shelf_product_map")
    op.drop_index("ix_shelf_product_map_shelf_product", table_name="shelf_product_map")
    op.drop_index("ix_shelf_product_map_store_id", table_name="shelf_product_map")
    op.drop_index("ix_shelf_product_map_tenant_id", table_name="shelf_product_map")
    op.drop_table("shelf_product_map")
    op.drop_index("ix_shelves_zone_id", table_name="shelves")
    op.drop_index("ix_shelves_store_zone", table_name="shelves")
    op.drop_index("ix_shelves_store_id", table_name="shelves")
    op.drop_index("ix_shelves_tenant_id", table_name="shelves")
    op.drop_table("shelves")
    op.drop_index("ix_zones_store_name", table_name="zones")
    op.drop_index("ix_zones_store_id", table_name="zones")
    op.drop_index("ix_zones_tenant_id", table_name="zones")
    op.drop_table("zones")

    conn = op.get_bind()
    for code, _, _ in PERMISSIONS:
        conn.execute(
            sa.text("DELETE FROM role_permissions WHERE permission_id = (SELECT id FROM permissions WHERE code = :code)"),
            {"code": code},
        )
        conn.execute(sa.text("DELETE FROM permissions WHERE code = :code"), {"code": code})
