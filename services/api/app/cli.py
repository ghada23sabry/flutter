"""Management CLI: provision tenants and admin users.

Usage:
  python -m app.cli create-tenant --name "Acme" --slug acme --email owner@acme.com --password secret
  python -m app.cli create-tenant --name "Acme" --slug acme --email owner@acme.com --password secret --store "Downtown"
  python -m app.cli create-admin --slug acme --email manager@acme.com --password secret
"""
import argparse
import asyncio
import sys

from sqlalchemy import select
from sqlalchemy.exc import IntegrityError

from app.core.audit import write_audit
from app.core.db import SessionLocal
from app.core.security import hash_password
from app.models import Role, Store, Tenant, User, UserRole


async def _get_role(db, name: str) -> Role | None:
    return (
        await db.execute(select(Role).where(Role.tenant_id.is_(None), Role.name == name, Role.is_system.is_(True)))
    ).scalar_one_or_none()


async def create_tenant(args: argparse.Namespace) -> int:
    async with SessionLocal() as db:
        try:
            tenant = Tenant(name=args.name, slug=args.slug)
            db.add(tenant)
            await db.flush()

            store = None
            if args.store:
                store = Store(tenant_id=tenant.id, name=args.store)
                db.add(store)
                await db.flush()

            owner_role = await _get_role(db, "owner")
            if owner_role is None:
                print("error: system owner role not seeded; run `alembic upgrade head` first", file=sys.stderr)
                return 1

            user = User(
                tenant_id=tenant.id,
                email=args.email,
                name=args.name + " Owner",
                password_hash=hash_password(args.password),
                status="active",
            )
            db.add(user)
            await db.flush()

            db.add(UserRole(user_id=user.id, role_id=owner_role.id, store_id=store.id if store else None))
            await write_audit(
                db,
                action="tenant_provisioned",
                entity_type="tenant",
                entity_id=str(tenant.id),
                tenant_id=tenant.id,
                store_id=store.id if store else None,
                user_id=user.id,
                after={"slug": tenant.slug, "plan": tenant.plan},
            )
            await db.commit()
        except IntegrityError as exc:
            await db.rollback()
            print(f"error: conflict (tenant slug, email, or store already exists): {exc.orig}", file=sys.stderr)
            return 1

    print(f"tenant={tenant.slug} id={tenant.id} user={user.email} role=owner")
    print(f"store={'created' if store else 'none'} id={store.id if store else '-'}")
    return 0


async def create_admin(args: argparse.Namespace) -> int:
    async with SessionLocal() as db:
        try:
            tenant = (
                await db.execute(select(Tenant).where(Tenant.slug == args.slug))
            ).scalar_one_or_none()
            if tenant is None:
                print(f"error: tenant slug not found: {args.slug}", file=sys.stderr)
                return 1

            admin_role = await _get_role(db, "admin")
            if admin_role is None:
                print("error: system admin role not seeded; run `alembic upgrade head` first", file=sys.stderr)
                return 1

            user = User(
                tenant_id=tenant.id,
                email=args.email,
                name=args.name,
                password_hash=hash_password(args.password),
                status="active",
            )
            db.add(user)
            await db.flush()
            db.add(UserRole(user_id=user.id, role_id=admin_role.id, store_id=None))
            await write_audit(
                db,
                action="user_provisioned",
                entity_type="user",
                entity_id=str(user.id),
                tenant_id=tenant.id,
                user_id=user.id,
                after={"role": "admin", "tenant_wide": True},
            )
            await db.commit()
        except IntegrityError as exc:
            await db.rollback()
            print(f"error: conflict (email already exists): {exc.orig}", file=sys.stderr)
            return 1

    print(f"user={user.email} id={user.id} role=admin tenant={tenant.slug}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(prog="visionstock", description="VisionStock AI management CLI")
    subparsers = parser.add_subparsers(dest="command", required=True)

    create_tenant_parser = subparsers.add_parser("create-tenant", help="Provision a tenant, owner user, and optional store")
    create_tenant_parser.add_argument("--name", required=True)
    create_tenant_parser.add_argument("--slug", required=True)
    create_tenant_parser.add_argument("--email", required=True)
    create_tenant_parser.add_argument("--password", required=True)
    create_tenant_parser.add_argument("--store", help="First store name (optional)")

    create_admin_parser = subparsers.add_parser("create-admin", help="Create an admin user in an existing tenant")
    create_admin_parser.add_argument("--slug", required=True)
    create_admin_parser.add_argument("--email", required=True)
    create_admin_parser.add_argument("--password", required=True)
    create_admin_parser.add_argument("--name", default="Admin")

    args = parser.parse_args()
    if args.command == "create-tenant":
        return asyncio.run(create_tenant(args))
    if args.command == "create-admin":
        return asyncio.run(create_admin(args))
    return 1


if __name__ == "__main__":
    sys.exit(main())
