# VisionStock AI — PROJECT_MAP.md

> External memory (memory ledger). Updated: **2026-08-12** (system date: 2026-08-12, UTC+2).
> Maintainers MUST update this file whenever the stack, flow, or architecture changes.

---

## [TECH_STACK]

All versions verified against official registries (PyPI / python.org / postgresql.org / GitHub / pub.dev) on **2026-08-10**. Pin exactly; nothing deprecated is used.

### Backend (Python / FastAPI)

| Component | Version (stable) | Verified | Notes |
|---|---|---|---|
| Python (prod image) | **3.14.7** | 2026-08-05 | Docker image `python:3.14-slim`. Local dev host: **3.13.15** (FastAPI supports ≥3.10) — recorded, not a blocker. |
| FastAPI | **0.141.1** | 2026-07-29 | Current stable. Pydantic v2 native, OpenAPI 3.1. Requires Python ≥3.10. |
| Uvicorn | latest `[standard]` | lock at setup | ASGI server. |
| SQLAlchemy | **2.0.51** | 2026-06-15 | 2.1.x is still **beta — do not use**. Async via `ext.asyncio`. |
| Alembic | **1.19.1** | 2026-08-08 | Async migrations (`run_async()`). |
| Pydantic | **v2.x** (FastAPI dep) | — | `pydantic-settings` for config. |
| asyncpg | latest | lock at setup | Async Postgres driver (`postgresql+asyncpg://`). |
| PyJWT | latest | lock at setup | JWT encode/decode. |
| passlib[bcrypt] | latest | lock at setup | Password hashing. |
| email-validator | latest | 2026-08-11 | Added for Pydantic `EmailStr` in auth schemas. |
| firebase-admin | latest | lock at setup | Server-side FCM push. |
| smtplib (stdlib) | stdlib | — | Supplier email automation — no extra dep in MVP. |

### AI / Computer Vision

| Component | Version (stable) | Verified | Notes |
|---|---|---|---|
| Ultralytics | **8.4.115** | 2026-08-01 | **Avoid yanked 8.4.35 & 8.4.44.** License = **AGPL-3.0 — commercial flag for SaaS (review before launch).** |
| YOLO model family | **YOLO26** (Jan 2026) | — | End-to-end, native inference; generic detection ONLY (never a global SKU classifier). |
| OCR | Tesseract / PaddleOCR | lock at setup | Assistance only (label/name read) — never sole identity source. |

### Mobile (Flutter)

| Component | Version (stable) | Verified | Notes |
|---|---|---|---|
| Flutter | **3.44.9** | 2026-08-05 | Dart 3.12.2. Impeller default on Android (Skia removed Android 10+); SwiftPM default on iOS (CocoaPods phase-out). |
| camera | **0.11.0** | 2026-08-18 | Flutter official camera plugin. Manual capture via `takePicture()`. Used for AI photo capture. |
| mobile_scanner | **7.4.0** | 2026-08-18 | Barcode/QR recognition via ML Kit. Used for barcode scanning only — NOT for photo capture. Coexists with `camera` plugin; exclusive camera ownership enforced. |
| firebase_messaging | **16.5.0** | 2026-08-03 | FCM push. |
| flutter_secure_storage | latest | lock at setup | Android Keystore / iOS Keychain for tokens. |
| sqflite / drift | latest | lock at setup | Local cache + offline sync queue (SQLite). |
| http / dio | latest | lock at setup | REST client. |
| httpx | **>=0.27,<1** | 2026-08-17 | Async HTTP client for AI vision provider calls (server-side). |

### Database & Infra

| Component | Version (stable) | Verified | Notes |
|---|---|---|---|
| PostgreSQL | **18.4** | 2026-05-11 | PG19 is **beta — do not use** (GA Sept 2026). PG14 EOL 2026-11-12. Local dev: portable binaries (user-scope, no service). |
| Docker / docker-compose | latest | files authored | **Live Docker verification PENDING on this host** (no Admin / no WSL2). |
| Git + GitHub | git 2.50.0 (local) | — | CI/CD (GitHub Actions) deferred to post-MVP. |

### Deprecation / risk register (MUST respect)
- SQLAlchemy 2.1.x beta — rejected. Flutter Material/Cupertino now **frozen in core**, migrating to `material_ui`/`cupertino_ui` packages — start on stable core APIs only.
- Ultralytics AGPL-3.0 — legal review required before commercial SaaS launch (Option: swap model family behind `AIVisionPort`; architecture isolates it).

---

## [RELEASE_0_1_SCOPE]

**Approved Release 0.1 scope** (explicitly represented here as the product deliverable). Release 0.1 = the scope-freeze target that spans M1–M6. Docs-only representation; no implementation before M1 approval.

| # | Capability (must ship in Release 0.1) | Milestone(s) | Notes / gap vs previous doc |
|---|---|---|---|
| 1 | **Dashboard** | M5 | Previously only "Dashboard + Analytics + AI Insights" — now explicit Dashboard module in R0.1. |
| 2 | **Full POS / Cashier System** | M3 | SYSTEM_FLOW A: search/SKU/barcode → cart → checkout → atomic sale+stock-deduct → receipt → offline sync. |
| 3 | **Products / Catalog** | M2 | Tenant/store-scoped catalog, categories, **Product Visual Profiles** (multiple ref images). |
| 4 | **Inventory Management** | M2 | Current stock, `inventory_transactions` audit, low/out/expiry computed, adjustment w/ audit. |
| 5 | **Manual Inventory Count** | M2 | Explicit manual count flow (expected vs actual, variance, audit). Was implicit — now explicit. |
| 6 | **Barcode / QR Inventory Count** | M2 + M3 | `camera` plugin scan-count flow. Was implicit — now explicit. |
| 7 | **AI Camera Inventory Count** | M4 | Store-aware AI scan (YOLO26 + barcode/OCR/visual match) — non-blocking, confidence<threshold → Needs Review. |
| 8 | **Suppliers** | M2 | Supplier entities linked to catalog + purchasing. |
| 9 | **Purchasing / Purchase Orders** | M6 | PO Draft→Approved→Sent(email)→Confirmed→Received(stock-in). |
| 10 | **Reports** | M5 | Explicit Reports module (derived via queries, no analytics table). Was implicit under "Analytics" — now explicit. |
| 11 | **Notifications** | M6 | DB notifications + FCM push; expiry tiers 30/14/7/0; low-stock/mismatch alerts. |
| 12 | **Users / Roles** | M1 | Auth + RBAC: roles/permissions, `user_roles`. |
| 13 | **Device Management** | M1 | Device register/active/lock/revoke; request gate checks device. |
| 14 | **Settings / Profile** | M1 + M6 | Tenant/store settings + user profile. Was not explicitly listed — now explicit. |

> Note: M2.5 (real dataset & store onboarding) remains a hard **prerequisite for M4** — Release 0.1 AI count cannot be DoD-verified without it.

---

## [MULTI_TENANCY]

**Core identity of the product: multi-tenant SaaS, NOT a single-supermarket app.**

### Tenant model
```
Tenant → Store → { Users, Devices, Catalog, Zones, Shelves, Inventory, Sales, Suppliers }
```
- One Tenant can own one or more Stores (Store is the operational unit).
- Every business entity row carries `tenant_id` (+ `store_id` where store-scoped).

### Mandatory request gate (every endpoint, no exceptions)
```
Authentication → Account Status → Device Authorization → Tenant → Store → Role → Permission → Resource
```
1. JWT valid → user loaded.
2. Account active (not disabled/deleted).
3. Device registered + active (not locked/revoked).
4. `tenant_id` resolved from token/context — **never from client params**.
5. `store_id` resolved from path/context and **must belong to the tenant**.
6. Role checked.
7. Permission checked against resource.
8. Row-level access: every query filters by `tenant_id` (+ `store_id`).

### Hard rules
- **No endpoint may rely on `user_id` alone** to fetch data — tenant/store context is mandatory on every query.
- Cross-tenant data must never be returned → 403/404 (404 preferred to avoid existence leak).
- `tenant_id`/`store_id` are enforced by shared `core.security` dependency (Protocol 3: shared only where truly repeated — this IS repeated everywhere).

---

## [SYSTEM_FLOW]

### A. Retail flow (POS) — verifiable journey (scope freeze target)
```
Cashier login (JWT) → device check (registered + active)
  → open POS → search by name/SKU OR barcode scan (camera plugin)
  → barcode→product→price→add to cart (qty +/- )
  → checkout: subtotal → discount → tax → total → pay (cash/card/other)
  → [TX] create sale + sale_items + decrement inventory + record user + device
  → audit_log + receipt
  → (offline) sale stored in Sync Queue → pushed on reconnect (idempotent)
```

### B. AI inventory scan flow (store-aware, zone/shelf scoped)
```
Open AI Scan (tenant + store + zone/shelf context from Store Setup)
  → camera → secure upload → POST /inventory/scan
  → persist scan + enqueue background job (non-blocking, single-process)
  → AI pipeline (see [AI_VISION_ARCHITECTURE])
  → Product/SKU + Count + Confidence
  → confidence < threshold → "Needs Review" (never auto-adjusts stock)
  → confidence ≥ threshold → Accept
  → reconcile: expected vs detected → variance + Inventory Accuracy %
  → triggers: low-stock / stockout-prediction / mismatch → notifications + FCM
```

### C. Purchasing flow
```
AI Recommendation (sales velocity + min/max + safety stock + historical sales)
  → manager edits quantities → create PO (Draft)
  → Pending Approval → Approved → Sent (SMTP email to supplier, logged) → Confirmed → Received (stock-in)
```

### D. Notification flow
```
Event (low stock/expiry/P.O/AI) → insert notifications (DB) → FCM push (firebase-admin) → Notification Center
Expiry tiers: 30d upcoming / 14d urgent / 7d critical / 0 expired. FEFO suggested order.
```

### E. Unknown product flow
```
AI: not enough confidence → "Unknown Product"
  → Review (in app) → user actions:
      register new product | scan barcode | enter name/SKU | pick category
      | add supplier | add reference images
  → product joins the store catalog → available for future scans
  → NO global model retraining for each new product
```

---

## [ARCHITECTURE]

Principles (Protocol 3): **Simplicity First** — single backend process; shared/core layer only for logic actually repeated; feature-domain grouping; **no micro-files, no microservices**. Multi-tenant isolation is enforced in `core.security`, not duplicated per feature.

### Repo layout (monorepo)
```
visionstock-ai/
├── apps/mobile/                 # Flutter 3.44.9 — thin client (no store DB on device)
│   ├── lib/
│   │   ├── main.dart
│   │   ├── app/                 # routing, DI, theme
│   │   ├── core/                # api_client, secure_storage, session, sync_queue
│   │   └── features/            # auth, pos, inventory, ai_scan, products, purchasing, dashboard, notifications
├── services/api/                # FastAPI 0.141.1 — single service, feature routers
│   ├── app/
│   │   ├── main.py
│   │   ├── core/                # config, db, security (tenant+RBAC+device+store), logging, notification dispatch
│   │   ├── models/              # SQLAlchemy grouped by domain (NOT one file per table)
│   │   ├── schemas/
│   │   ├── routers/             # one per feature
│   │   └── services/            # pos, stock, reconciliation, ai_vision, forecasting, purchase, email, fcm
│   ├── migrations/              # Alembic 1.19.1
│   ├── tests/
│   └── pyproject.toml + Dockerfile
├── ai/                          # dataset/ (YOLO format), training/, models/ (.pt/.onnx)
├── infra/                       # docker-compose.yml (api + postgres 18.4)
└── PROJECT_MAP.md
```

### Backend module map (engines — independent, composable)
```
core (shared): config | db.session | security(tenant+store+device+RBAC) | logging | notifications
auth      → routers/auth.py | services/auth_service.py
catalog   → products (store-scoped), categories, suppliers, product_visual_profiles
layout    → zones, shelves, shelf_positions (Store Setup Wizard data)
inventory → stock service, adjustment (+audit), scans, reconciliation
pos       → sales service (atomic sale+deduct), receipt
purchasing→ PO service (state machine), supplier email
ai        → AIVisionPort (adapter → vision pipeline) — replaceable, store-aware
intel     → forecasting (stockout/reorder/expiry risk), AI assistant (DB queries only)
system    → tenants, users/roles/permissions, devices, notifications, audit_logs
```

### Database (core tables — MVP)
See the authoritative **`[DATABASE_BLUEPRINT]`** section below (logical ERD, scope matrix, relationships, transaction boundaries). This bullet list is now superseded and kept only as a domain index:
- identity: `tenants`, `stores`, `users`, `roles`, `permissions`, `role_permissions`, `user_roles`, `devices`, `device_sessions`
- layout: `zones`, `shelves`, `shelf_product_map`
- catalog: `categories`, `products` (tenant+store scoped), `product_visual_profiles`, `product_visual_embeddings`, `suppliers`, `supplier_products`, `expiry_batches`
- sales: `sales`, `sale_items`, `payments`
- inventory: `inventory`, `stock_movements`, `inventory_count_sessions`, `inventory_count_items`, `inventory_adjustments`, `reconciliations`
- purchasing: `purchase_orders`, `purchase_order_items`
- ai: `ai_scan_sessions`, `ai_detections`
- system: `notifications`, `audit_logs`

### Logging strategy (Protocol 4) — async & minimal
- Backend `core/logging.py`: stdlib `logging` + `QueueHandler`/`QueueListener` (**non-blocking**), `RotatingFileHandler` (10 MB × 5) + console; levels **DEBUG/INFO/WARNING/ERROR** only; structured JSON-lines with request-id correlation.
- **Never** log tokens, passwords, or PII. Sensitive mutations go to DB `audit_logs`, not logs.
- Mobile: `dart:developer log()`/debugPrint; no network telemetry in MVP.

### Decision log (what we rejected — protocol 3)
- Rejected: microservices / separate AI service (same process behind `AIVisionPort`; extractable later).
- Rejected: Redis/Celery in MVP (async background tasks suffice); revisit under load.
- Rejected: `analytics` storage table — derive dashboards via queries.
- Rejected: GraphQL, multi-tenant sharding, multi-package backend split.
- Rejected (AI): global SKU classifier AND per-customer dedicated models (see [AI_VISION_ARCHITECTURE]).

---

## [DATABASE_BLUEPRINT]

Logical design review for **Release 0.1** (docs only — no migrations created yet). Authoritative source for M1+ schema work. Naming: `id` = UUID PK (client-generatable); every scoped row carries `tenant_id` (and `store_id` where store-scoped). `*_at` = timestamptz. Money = NUMERIC(14,2); quantities = NUMERIC(12,3). No soft-delete proliferation: `status` enums with `active/archived/disabled` instead.

### 1. Logical schema (by domain)

**Identity & tenancy**
| Table | Key columns | Notes |
|---|---|---|
| `tenants` | id, name, slug, plan, status(active/suspended/trial) | Top scoping root. |
| `stores` | id, **tenant_id**, name, address, timezone, currency, status | Operational unit. |
| `users` | id, tenant_id (nullable→platform admin), email, phone, name, password_hash, status(active/disabled) | |
| `roles` | id, tenant_id (nullable=system role), name, is_system | RBAC roles. |
| `permissions` | id, code (unique, e.g. `pos.checkout`), domain, description | Global permission catalog. |
| `role_permissions` | role_id, permission_id | M2M. |
| `user_roles` | id (UUID PK), user_id, role_id, store_id (nullable) | Role can be store-scoped. **2026-08-11:** composite PK `(user_id, role_id, store_id)` was invalid in Postgres (PK columns are implicitly NOT NULL → tenant-wide roles with NULL store_id were uninsertable). Replaced with surrogate `id` PK + `UNIQUE(user_id, role_id, store_id)` (NULLs distinct in PG unique). |
| `devices` | id, **tenant_id**, **store_id**, name, platform, fcm_token, status(active/locked/revoked), last_seen_at | Registered cashier devices. |
| `device_sessions` | id, device_id, user_id, token_hash, ip, user_agent, started_at, ended_at, revoked_at | |

**Layout (store setup)**
| Table | Key columns |
|---|---|
| `zones` | id, **tenant_id**, **store_id**, name, code |
| `shelves` | id, **tenant_id**, **store_id**, zone_id, label, code, position |
| `shelf_product_map` | id, **tenant_id**, **store_id**, shelf_id, product_id, position, is_primary |

**Catalog**
| Table | Key columns | Notes |
|---|---|---|
| `categories` | id, **tenant_id**, **store_id**, parent_id (nullable), name, code | |
| `products` | id, **tenant_id**, **store_id**, category_id, name, sku (unique per store), barcode (nullable), unit, price, cost, min_stock, max_stock, status(active/archived) | |
| `product_visual_profiles` | id, **tenant_id**, **store_id**, product_id, label, reference_image_url, is_default | Multiple ref images/product. |
| `product_visual_embeddings` | id, **tenant_id**, **store_id**, product_id, profile_id, vector, model_version | `vector` = pgvector later; JSONB float array on local until then (see §9). |

**Suppliers**
| Table | Key columns |
|---|---|
| `suppliers` | id, **tenant_id**, name, contact_name, email, phone, address, status |
| `supplier_products` | id, **tenant_id**, supplier_id, product_id, unit_cost, lead_time_days, is_preferred |

**Inventory**
| Table | Key columns | Notes |
|---|---|---|
| `inventory` | id, **tenant_id**, **store_id**, product_id (unique per store), quantity, reserved_quantity, reorder_point, version (optimistic lock) | Current stock per store/product. |
| `stock_movements` | id, **tenant_id**, **store_id**, product_id, quantity_delta, reason(SALE/PURCHASE_RECEIPT/ADJUSTMENT/COUNT/EXPIRY_WRITEOFF), reference_type, reference_id, created_by, created_at | Append-only ledger; every change traceable. |
| `expiry_batches` | id, **tenant_id**, **store_id**, product_id, batch_code, quantity, expiry_date, received_at | FEFO basis. |

**Sales / POS**
| Table | Key columns | Notes |
|---|---|---|
| `sales` | id, **tenant_id**, **store_id**, device_id, cashier_user_id, invoice_no, subtotal, discount, tax, total, status(completed/refunded/voided), sale_time, **idempotency_key UNIQUE** | Idempotency key = retry-safe checkout. |
| `sale_items` | id, sale_id, product_id, quantity, unit_price, line_total, discount | |
| `payments` | id, sale_id, method(CASH/CARD/OTHER), amount, reference, paid_at | |

**Purchasing**
| Table | Key columns | Notes |
|---|---|---|
| `purchase_orders` | id, **tenant_id**, **store_id**, supplier_id, po_no, status(draft/pending_approval/approved/sent/confirmed/received/cancelled), order_date, expected_date, received_at, total, created_by, approved_by | State machine. |
| `purchase_order_items` | id, purchase_order_id, product_id, quantity_ordered, quantity_received, unit_cost, line_total | |

**Counts (manual / barcode-QR / AI) — unified**
| Table | Key columns | Notes |
|---|---|---|
| `inventory_count_sessions` | id, **tenant_id**, **store_id**, zone_id, shelf_id, method(MANUAL/BARCODE_QR/AI), status(draft/in_progress/awaiting_review/confirmed/cancelled), started_by, confirmed_by, created_at, completed_at | One table for all three count modes. |
| `inventory_count_items` | id, session_id, product_id, expected_qty, counted_qty, variance, status(pending/matched/mismatch/review), counted_by, noted_at | Per product in a session. |
| `inventory_adjustments` | id, **tenant_id**, **store_id**, product_id, session_id, quantity_delta, reason, created_by, created_at | Only accepted differences. |
| `reconciliations` | id, **tenant_id**, **store_id**, product_id, source(SESSION/AI_SCAN), session_id, ai_scan_session_id, expected_qty, counted_qty, variance, accuracy_pct, status(accepted/needs_review), resolved_at, resolved_by | Per-product reconciliation outcome; single domain for manual + AI. |

**AI scan**
| Table | Key columns | Notes |
|---|---|---|
| `ai_scan_sessions` | id, **tenant_id**, **store_id**, zone_id, shelf_id, started_by, status(pending/processing/completed/failed), image_count, created_at, completed_at | |
| `ai_detections` | id, ai_scan_session_id, product_id (nullable), barcode, confidence, count, bbox (JSONB), status(accepted/needs_review), created_at | Low-confidence → needs_review, never auto-adjusts. |

**System**
| Table | Key columns | Notes |
|---|---|---|
| `notifications` | id, **tenant_id**, store_id, user_id (target), type(LOW_STOCK/EXPIRY/PO/AI_REVIEW/…), title, body, read_at, created_at | |
| `audit_logs` | id, tenant_id, store_id, user_id, action, entity_type, entity_id, before (JSONB), after (JSONB), ip, created_at | Append-only. |

### 2. Entity Scope Matrix

Scope is assigned deliberately — **no `tenant_id` added where not needed, but no cross-tenant read is possible**.

| Entity | Scope | `tenant_id` | `store_id` |
|---|---|---|---|
| `tenants` | GLOBAL | — (is the root) | — |
| `permissions` | GLOBAL | — | — |
| `roles` (system rows) | GLOBAL | nullable (NULL = system) | — |
| `roles` (custom) | TENANT-SCOPED | required | — |
| `role_permissions` | TENANT/GLOBAL | via role | — |
| `users` | TENANT-SCOPED | required (nullable only for platform admin) | — |
| `user_roles` | TENANT-SCOPED | via user/role | nullable (store-scoped role) |
| `suppliers` | TENANT-SCOPED | required | — |
| `supplier_products` | TENANT-SCOPED | required | — (store via product) |
| `stores` | TENANT-SCOPED | required | — |
| `devices` | TENANT-SCOPED | required | required |
| `zones` | STORE-SCOPED | required | required |
| `shelves` | STORE-SCOPED | required | required |
| `shelf_product_map` | STORE-SCOPED | required | required |
| `categories` | STORE-SCOPED | required | required |
| `products` | STORE-SCOPED | required | required |
| `product_visual_profiles` | STORE-SCOPED | required | required |
| `product_visual_embeddings` | STORE-SCOPED | required | required |
| `inventory` | STORE-SCOPED | required | required |
| `expiry_batches` | STORE-SCOPED | required | required |
| `inventory_count_sessions` | STORE-SCOPED | required | required |
| `inventory_count_items` | STORE-SCOPED | required | required (via session) |
| `reconciliations` | STORE-SCOPED | required | required |
| `ai_scan_sessions` | STORE-SCOPED | required | required |
| `ai_detections` | STORE-SCOPED | required | required (via session) |
| `purchase_orders` | STORE-SCOPED | required | required |
| `purchase_order_items` | STORE-SCOPED | required | required (via PO) |
| `device_sessions` | DEVICE-SCOPED | required | required (via device) |
| `sales` | TRANSACTION-SCOPED | required | required |
| `sale_items` | TRANSACTION-SCOPED | via sale | via sale |
| `payments` | TRANSACTION-SCOPED | via sale | via sale |
| `stock_movements` | TRANSACTION-SCOPED | required | required |
| `inventory_adjustments` | TRANSACTION-SCOPED | required | required |
| `notifications` | USER-SCOPED | required | optional (via store) |
| `audit_logs` | TENANT-SCOPED | required (nullable only for system-level) | optional |

### 3. Critical relationships (verified against Release 0.1)

```
Tenant 1─N Store
Store 1─N Zone; Zone 1─N Shelf
Store 1─N Product; Store 1─N Category; Category 1─N Product
Product N─N Supplier  (via supplier_products: supplier_id + product_id + unit_cost/lead_time)
Product 1─N ProductVisualProfile 1─N ProductVisualEmbedding
Product 1─1 Inventory (per store); Product 1─N ExpiryBatch
Shelf 1─N ShelfProductMap N─1 Product  (positional mapping; feeds AI zone/shelf context)
Sale 1─N SaleItem N─1 Product; Sale 1─N Payment
Sale 1─N StockMovement  (reference_type='SALE', reference_id=sale.id)
InventoryCountSession 1─N InventoryCountItem N─1 Product
InventoryCountSession → (confirm) → Reconciliation 1─1 Product  → InventoryAdjustment(s) → StockMovement(COUNT) → Inventory
AIScanSession 1─N AIDetection (product_id nullable; confidence) → accepted → CountSession(method=AI)/Reconciliation → Adjustment
PurchaseOrder 1─N PurchaseOrderItem N─1 Product; PurchaseOrder N─1 Supplier
PurchaseOrder(status=received) → StockMovement(PURCHASE_RECEIPT) → Inventory qty += received  (atomic, same transaction)
Device 1─N DeviceSession; User 1─N DeviceSession
User 1─N Notification (target); User N─N Role (user_roles) N─N Permission (role_permissions)
```

### 4. POS transaction boundary (atomicity)

Checkout runs in **one database transaction** (single FastAPI process, one async session):

```
BEGIN
  1. SELECT inventory … FOR UPDATE  (per product, ordered by product_id → no deadlock)
  2. INSERT sale(status=completed, idempotency_key)   — unique key ⇒ retry is a no-op
  3. Validate each sale_item: qty ≤ inventory.quantity (+ reserved)
  4. INSERT sale_items, INSERT payments
  5. INSERT stock_movements(delta = -qty, reason=SALE, ref=sale.id)
  6. UPDATE inventory.quantity -= qty
  7. INSERT audit_log(sale, user, device)
COMMIT      (any failure ⇒ ROLLBACK; nothing partially persisted)
```
Concurrency: pessimistic row locks (`FOR UPDATE`) + optimistic `inventory.version` guard for non-POS adjustments. Idempotency: client-generated `idempotency_key` unique on `sales`. Offline sync: local Sync Queue replays the same call with the same key → at most once.

### 5. Inventory / Reconciliation design (single domain, 3 input modes)

```
Mode MANUAL | BARCODE_QR | AI
   → inventory_count_sessions (method, zone/shelf context, status, started_by, confirmed_by, created_at, completed_at)
   → inventory_count_items   (expected_qty, counted_qty, variance, status)
        AI path: ai_scan_sessions → ai_detections → accepted (confidence≥threshold) fill count items;
                 needs_review never touches stock.
   → confirm session → reconciliations (expected vs counted, variance, accuracy %, accepted/needs_review)
   → inventory_adjustments (only accepted diffs; audited, reason=count)
   → stock_movements (reason=COUNT) + inventory update  (same transaction as the adjustment)
```
Manual, Barcode/QR and AI all converge on the **same** count-session → reconciliation → adjustment chain. No separate incompatible inventory systems.

### 6. Reporting data strategy (no analytics table)

Reports are derived by **queries/views over transactional data** (rejected: generic `analytics` table). Index targets: `(store_id, created_at)` on sales/stock_movements/purchase_orders; `(store_id, product_id)` on inventory/expiry_batches; status columns. Candidate SQL views (created only when reports are implemented, M5): sales_by_period, stock_value, low_stock, expiry_lookup, cashier_performance, po_by_supplier, stock_movement_ledger, count_accuracy. Supports: Sales / Inventory / Purchasing / Supplier / Cashier / Expiry / Low-Stock / Stock-Movement / AI-Inventory reports.

### 7. AI / Vector preparation (pgvector NOT installed now)

- `product_visual_embeddings.vector`: **expected dimension = 512** (default; configurable via `VISION_EMBEDDING_DIM`). Must match the chosen vision encoder (adapter in `AIVisionPort` records `model_version` per row).
- Dependency: `pgvector` extension — required in staging/CI, **not available in local portable PG18** (verified: no `vector.control`). No install/configure now.
- Migration strategy:
  1. Base migration ships the column as **JSONB float array** (works everywhere; no extension).
  2. Conditional pgvector migration (staging only): `CREATE EXTENSION IF NOT EXISTS vector;` then `ALTER TABLE … ALTER COLUMN vector TYPE vector(512) USING vector::vector(512);` + **HNSW/IVFFlat** index.
  3. `AIVisionPort` contract returns a `float[]`; persistence layer chooses storage → local dev unaffected, similarity search unlocked in staging.

---

## [AI_VISION_ARCHITECTURE]

### Non-negotiable principles
1. **No global SKU classifier** — the model never maps "all products of all customers".
2. **No per-customer dedicated models** (`Customer A→Model A`) — not scalable.
3. Identity comes from **Tenant-specific Product Visual Profiles + Barcode + OCR**, not from a global class list.
4. Generic detection (YOLO26) finds *objects*, catalog matching assigns *products*.

### Pipeline (M4)
```
Image
 → Preprocessing (normalize/lighting/scale)
 → Object Detection (YOLO26 — generic, bounding boxes)
 → Barcode Detection (highest-priority identity when readable)
 → Visual Product Matching (against tenant-specific visual profiles)
 → OCR assistance (label/name/size text — supporting signal only)
 → Tenant-specific Catalog Matching (constrained to store relevant catalog)
 → Product/SKU + Count
 → Inventory Reconciliation
```

### Hybrid recognition priority (order of trust)
1. **Barcode** when available → exact product match.
2. **Visual Product Matching** against the store's Product Visual Profiles.
3. **OCR** assist.
4. **Generic Object Detection** (object present, identity unconfirmed).
5. **Unknown Product** when confidence < threshold — never guess.

### Confidence & human review (hard rule)
- `confidence ≥ threshold → Accept` (may update reconciliation).
- `confidence < threshold → Needs Review` → routed to [SYSTEM_FLOW] E.
- **No low-confidence identification is recorded as confirmed product.**
- Threshold is **configurable** (per tenant/store setting), never hard-coded.
- Inventory is **never** modified directly from a prediction; adjustments are explicit, audited actions.

### Store-aware execution (M4 requirement)
- Scan context carries `tenant_id`, `store_id`, `zone_id`, `shelf_id` (when present).
- Matching restricted to the **relevant catalog** (zone/shelf-relevant subset) — never the full catalog of all tenants.
- Goal: higher accuracy + lower latency + lower compute cost.

### Isolation (unchanged, mandatory)
```
Inventory Service → AIVisionPort → Current Vision Adapter (YOLO26/OCR)
```
Business logic never depends on a concrete model. Model swap = new adapter only.

---

## [DATASET_STRATEGY]

### M2.5 — Real Dataset & Store Onboarding (BLOCKER for M4)
One real store onboarded with:
- 100–300 real products (min start) with: barcode, SKU, product metadata.
- **Multiple reference images per product** (angle/lighting variance → robust visual matching).
- Real shelf photos.
- Real inventory quantities.
- Shelf/Zone mapping (Store Setup Wizard).
- **Ground truth inventory recorded** → enables AI accuracy evaluation.

### Rules
- Real data only — no mock-data passes as evaluation.
- M4 is **not considered ready** without a testable real dataset.
- New products join the tenant catalog via Unknown Product flow — **no global retraining**.

---

## [UI_DESIGN_SYSTEM] — Flutter foundation (M0.5)

Applied on **2026-08-11** in `apps/mobile/lib/core/`. First business screen (auth login) landed the same day; core widget library remains feature-agnostic.

| Area | Files | Contents |
|---|---|---|
| Tokens | `theme/app_tokens.dart` | `AppColors` (seed + success/warning/error/info/neutral + containers), `AppSpacing` (2–48 scale), `AppRadius` (8/12/16/pill), `AppTypography` (11–34). |
| Theme | `theme/app_theme.dart` | `AppTheme.build(brightness)` — Material 3, `ColorScheme.fromSeed(AppColors.seed)`, text styles, input decoration, button shapes (pill), card, chip, progress, snackbar themes. |
| Core widgets | `widgets/app_button.dart` | `AppButton` — variants primary/secondary/outline/text; sizes sm/md/lg; loading spinner; optional icon; full-width toggle. |
| | `widgets/app_input.dart` | `AppInput` — label, hint, error, prefix icon, obscure, keyboard type, enabled. |
| | `widgets/app_card.dart` | `AppCard` — optional tap, default padding. |
| | `widgets/status_badge.dart` | `StatusBadge` + `AppStatus` (success/warning/error/info/neutral). |
| | `widgets/loading_state.dart` | `LoadingState` — centered spinner + optional message. |
| | `widgets/error_state.dart` | `ErrorState` — title/message + optional retry. |
| | `widgets/empty_state.dart` | `EmptyState` — icon, title, message, optional action. |
| App shell | `main.dart` | `VisionStockApp` (MaterialApp light/dark) → `AuthGate` (restore session → `LoginScreen` or `AppShell`). No feature screens yet. |
| Auth (M1) | `features/auth/login_screen.dart`, `features/auth/auth_gate.dart`, `core/api_client.dart`, `core/session.dart`, `core/session_store.dart`, `core/api/auth_api.dart`, `core/models/auth_models.dart`, `core/config.dart` | Login UI on the design system; session persistence via secure storage; typed API errors. |
| Test | `test/widget_test.dart`, `test/login_flow_test.dart` | Smoke: shell renders with theme; login flow (render/login→home/401/restore/sign-out). Live e2e: `test/live_integration_test.dart` (real Flutter→HTTP→FastAPI→PG, opt-in via `--dart-define=LIVE_API=true`). |

`flutter analyze` clean · `flutter test` → 6 passed (+6 live e2e with `LIVE_API=true`).

---

## [ORPHANS & PENDING]

| Item | Status | Blocker / Action |
|---|---|---|
| **M2.5 dataset**: 100–300 real products + multiple reference images + shelf photos + real qty + shelf/zone mapping + ground truth | PENDING | Hard blocker for M4. Owner must onboard 1 real store. |
| Fine-tuned/tuned vision adapter weights | PENDING | Generic YOLO26 first; tuned on store photos after M2.5. |
| Firebase project + `google-services.json` + FCM credentials | PENDING | Owner creates Firebase project. |
| SMTP credentials / sender mailbox | PENDING | Owner provides; MVP uses stdlib smtplib. |
| **Docker live verification** (docker-compose up) | PENDING | Host has no Admin/WSL2. Files authored; verify on CI/Docker-ready host. |
| Ultralytics AGPL-3.0 license review (commercial SaaS) | PENDING | Legal decision — may swap model family behind `AIVisionPort`. |
| Flutter full Android build (APK) | IN PROGRESS 2026-08-13 | Android SDK 36 + ADB + physical Samsung A15 + host→backend network now verified (see `[M0_VERIFICATION]`). First APK build hit JVM native-memory exhaustion on the ~7 GB RAM host; Gradle JVM/worker settings were reduced and the build re-run is stabilizing. **Final APK install + on-device execution is the only remaining unverified Android item.** |
| **M0 local env verified (Windows)** | DONE (env subset) 2026-08-11 | PG 18.4 portable up · `visionstock` DB · `alembic upgrade head` applied (0001 baseline) · `GET /health`=200 · `ruff check` clean · `pytest` 2/2 smoke · Flutter 3.44.9 project creates+analyzes. **M0 overall NOT COMPLETE** — APK/Docker/pgvector/CI remain blocked (see `[M0_VERIFICATION]`). Fixes: PG `shared_memory_type=windows` (ASLR/AV 487), `app/core/logging.py` `Queue` import. |
| **M0.5 prep** | DONE 2026-08-11 | Android toolchain inspected (APK **BLOCKED** — no Android SDK/adb; JDK 24.0.1 present, AGP 9.0.1/Gradle 9.1.0 need JDK 17+; signing not configured — see `[M0_VERIFICATION]`). `[DATABASE_BLUEPRINT]` authored (logical ERD, scope matrix, POS atomicity, unified count/reconciliation, reporting strategy, pgvector prep). `[UI_DESIGN_SYSTEM]` foundation landed (tokens/theme/core widgets; analyze clean, test passes). No M1 implementation. |
| **M1 auth core (backend)** | DONE (subset) 2026-08-11 | `alembic 0002` (identity+audit schema, seeded 10 permissions + system `owner`/`admin` roles). `core/security` auth chain (JWT→account→device→tenant→store→role→perm). Routers: `/auth/login|refresh|logout|me`, `/devices` (list/register/revoke), `/users/me`. Refresh rotation, device auto-register on login, revoke kills sessions, audit via `audit_logs`, cross-tenant = 404, no-permission = 403. CLI `python -m app.cli create-tenant|create-admin`. **Tests: 15 passed** (auth flows incl. tenant isolation, store-scoped cashier, cashier→403 on owner endpoint), `ruff check` clean. |
| **M2 catalog (backend)** | DONE (subset) 2026-08-11 | `alembic 0003` (catalog schema: `categories`, `products`, `product_visual_profiles`, `suppliers`, `supplier_products` + seed 4 permissions `categories.view/manage`, `suppliers.view/manage` granted to system `owner`/`admin`). Routers: `/categories` (list/create/get/patch), `/products` (list w/ `q` search + pagination, create, get, `lookup/sku|barcode` with canonical barcode normalization, patch, `/products/{id}/suppliers`), `/suppliers` (list/create/get/patch, `/{id}/products` link/update/unlink). Tenant/store scoping via shared `catalog_service` helpers (`get_scoped_product/category/supplier`, `require_store`, `normalize_barcode`, `clean_required`). Cross-tenant/cross-store = 404, no-permission = 403, uniqueness = 409, blank required fields = 422, self-parent category = 422. Audit write on every mutation. **Tests: 27 passed** (12 new catalog: auth gate, 403 on all 3, CRUD, duplicate sku/code 409, blank name 422, self-parent 422, barcode normalization, supplier link/unlink 409, cross-tenant 404, cross-store 404), `ruff check` clean. |
| **M3 inventory (mobile)** | DONE 2026-08-12 | Flutter inventory feature end-to-end: data layer (`inventory_models.dart`, `inventory_api.dart`), 13 presentation screens, RBAC-gated Inventory tab in `app_shell.dart` (`inventory.view` + granular permission gates for adjust/layout/expiry/movements), 6 widget tests, and 4 live E2E tests (`test/live_inventory_test.dart`, idempotent, twice-green) covering stock/opening/delta-adjust/movements, layout mapping, expiry lifecycle, and the RBAC boundary. Backend additions this session: delta-based adjustment (concurrency-proof) + `GET /inventory/shelves/{shelf_id}/products`. Backend suite now **45 passed**; `flutter analyze` clean; `flutter test` 17 passed. See `[M3_INVENTORY_STATUS]`. **Scope note:** M3 as executed = Inventory feature; the `[MILESTONES]` M3=POS line is unchanged and POS is still pending. |
| **M1 auth (mobile login)** | DONE (subset) 2026-08-11 | Flutter: `core/api_client.dart` (typed errors from backend envelope), `core/session_store.dart` (`SecureSessionStorage`/`MemorySessionStorage`), `core/session.dart` (`SessionController` restore/login/logout), `core/api/auth_api.dart`, `features/auth/login_screen.dart` (design-system UI), `features/auth/auth_gate.dart` (startup restore gate), `features/home/app_shell.dart` (session home + sign-out). Deps added: `http`, `flutter_secure_storage` (minSdk OK: flutter.minSdkVersion 24 ≥ 23). **`flutter analyze` clean · `flutter test` 6/6 passed** (render, login→home, 401 error, restore, sign-out). **Live e2e GREEN 2026-08-11**: `test/live_integration_test.dart` 6/6 (real login→Home, `/auth/me`, logout local+server revoke, invalid creds UX, invalid token 401) against live FastAPI+PG. Real-HTTP gotcha solved: flutter_test's global mock `HttpOverrides` (returns 400) must be nulled while constructing the real `http.Client`; and `tester.pump(duration)` only advances the fake clock — real network needs a real-time `Future.delayed` between pumps inside `tester.runAsync`. **NOT YET**: auto refresh-token renewal on 401, device lock transition UX, Android emulator live run (no SDK/emulator on host). |
| **M4-A.5 HTTP API (backend)** | DONE 2026-08-13 | Thin `/ai` router over the M4-A service layer. `POST /ai/scans` (ai.scan), `POST /ai/scans/{id}/process` (ai.scan, raw image bytes, 20 MB cap), `GET /ai/scans/{id}` + `GET /ai/scans/{id}/detections` (ai.view), `GET /ai/scans/{id}/reconciliations` (ai.reconcile), `POST /ai/scans/{id}/confirm` (ai.confirm). Same envelope, 401/403/404/409/422 semantics, cross-tenant/store=404. Vision adapter injected via `get_vision_port_dependency` over the `AIVisionPort` composition root (overridable for tests). **24 HTTP tests passed** (unauth 401 · revoked device 401 · 4× missing-permission 403 · cross-tenant/store 404 · invalid shelf 404 · create/process · results · reconciliations · confirm · dup 409 · FAILED 409 · CANCELLED 409 · needs-review confirm needs ai.confirm · no inventory mutation on process · COUNT movement + audit on confirm · oversized image 422 · unknown session 404 · cross-tenant view 404). **Fresh-DB migration chain 0001→0007 verified** on disposable DB (tables/indexes/permissions/owner+admin grants/`uq_stock_movements_scan_count`). Full suite **114 passed**, `ruff check .` clean. Full contract + RBAC matrix in `[M4_A5_STATUS]`. |
| Automatic Shelf Detection | Future | Roadmap. MVP uses Store Setup Wizard context only. |
| CCTV integration / RTSP / Continuous Shelf Monitoring | Future | Roadmap. Architecture extensible, no implementation now. |
| Print/PDF receipt, POS hardware | DEFERRED | Post-MVP. |
| ERP, multi-branch, payment gateway, advanced forecasting | DEFERRED | Roadmap Phase 2/3. |
| GitHub Actions CI/CD | DEFERRED | Post-MVP. |
| iOS build (SwiftPM default) | DEFERRED | Android-first MVP. |
| Version locking for minor libs (asyncpg, PyJWT, uvicorn, mobile packages) | PENDING | Lock at setup via `uv pip compile` / `flutter pub`. |

---

## [M0_VERIFICATION]

**Status: M0 NOT COMPLETE — BLOCKED ITEMS REMAIN.** Verified on **2026-08-11** (Windows host, local). Do not open M1 until blocked items are resolved/re-verified.

### PASS (verified on local Windows host)
| Item | Evidence |
|---|---|
| Python venv | `.venv` (Python 3.13.15) in `services/api` |
| FastAPI | `fastapi==0.141.1` installed; app boots via uvicorn |
| SQLAlchemy | `sqlalchemy[asyncio]==2.0.51` (2.1.x beta rejected) |
| Alembic | `alembic==1.19.1`; baseline migration `0001` applied (`alembic upgrade head` + `current`) |
| asyncpg | `asyncpg==0.31.0`; async DB connectivity test passes |
| pytest installed | `pytest==9.1.1` + `pytest-asyncio==1.4.0` |
| ruff clean | `ruff check .` → "All checks passed!" |
| Alembic baseline migration | revision `0001` applied on `visionstock` DB |
| PostgreSQL connectivity | PG 18.4 portable up on `localhost:5432`; `SELECT version()` + smoke tests OK |
| GET /health = 200 | `{"status":"ok","database":"ok",...}` (incl. DB round-trip) |
| Flutter 3.44.9 | `flutter --version` → 3.44.9 stable (revision 6b182d2c75) |
| Dart 3.12.2 | bundled with Flutter 3.44.9 |
| flutter analyze clean | `apps/mobile` → "No issues found!" |
| M0 smoke tests | `pytest` → `2 passed` (`test_health_ok`, `test_database_connectivity`) |
| .env ignored | `git check-ignore -v services/api/.env` → matched `.gitignore:8:.env` |

### UNVERIFIED / BLOCKED (must be cleared before M0 can be marked complete)
| Item | Status | Blocker / Evidence |
|---|---|---|
| Android toolchain | **RESOLVED 2026-08-13** | Flutter Android toolchain PASS · Android SDK 36.0.0 (`C:\Android\Sdk`) · Platform 36 · Build Tools 36.0.0 · Platform Tools 37.0.1 · command-line tools recognized by Flutter · licenses all accepted. ADB functional; physical Samsung Galaxy A15 (`SM A155F`, `RK8X801M5WW`, android-arm64, Android 16/API 36) detected by Flutter. |
| Host → backend network | **RESOLVED 2026-08-13** | FastAPI on `0.0.0.0:8000`; host Wi-Fi IPv4 `192.168.1.2`; `Test-NetConnection 192.168.1.2 -Port 8000` → `TcpTestSucceeded : True`. |
| Android APK build | **IN PROGRESS** | First build failed on JVM native memory exhaustion (~7 GB RAM host) with `-Xmx8G / -MaxMetaspaceSize=4G / -ReservedCodeCacheSize=512m`; reduced to `-Xmx2G / -MaxMetaspaceSize=512m / -ReservedCodeCacheSize=256m`, `org.gradle.workers.max=1`, `org.gradle.parallel=false`, `kotlin.compiler.execution.strategy=in-process`. `flutter clean` + `flutter pub get` OK; subsequent build installed NDK 28.2.13676358 + SDK Platform 34/35. **Final APK install + on-device runtime still unverified until the current Gradle build completes successfully.** |
| Docker Compose | **ENVIRONMENT-BLOCKED** | `docker` command not found; no WSL2/Admin. Compose files authored, not run. |
| pgvector | **ENVIRONMENT-BLOCKED** | `CREATE EXTENSION vector` → "extension is not available"; no `vector.control` in portable `pgsql\share\extension`. |
| CI/CD | **PENDING** | GitHub Actions deferred to post-MVP by design. |

### Environment notes (real blockers only)
- Host: Windows 10 Pro 1903 (18362.1256), no Admin/WSL2, no Docker. Android toolchain AVAILABLE as of 2026-08-13 (SDK 36 + ADB + physical Samsung A15 — see rows above).
- Local PG18 ASLR/AV issue (`error code 487`) resolved via `shared_memory_type = windows` (see AGENTS.md Gotchas).
- pgvector requirement for staging: portable binaries must include pgvector (Windows build) or use Docker/linux image with `pgvector/pgvector` — decide at staging setup; architecture unchanged.

---

## [M1_M2_STATUS] — memory ledger update, verified 2026-08-12

**M1 (auth + RBAC + multi-tenant + devices)** — implemented and verified on local host (owner/cashier permission gating, device session checks, cross-tenant/store → 404, cross-tenant → 403 where role blocks).

**M2 — Catalog + Layout + Inventory (incremental).** Categories, products, suppliers were already landed earlier. This session landed **Store Layout + Inventory** (`migration 0004`, applied):

| Item | Status | Evidence |
|---|---|---|
| Migration `0004_inventory_schema` | APPLIED | `zones`, `shelves`, `shelf_product_map`, `inventory`, `stock_movements`, `expiry_batches` (+ indexes/constraints per blueprint) |
| Inventory permissions | SEEDED | `inventory.view / adjust / manage_layout / view_movements / manage_expiry` → system roles `owner`, `admin` |
| Layout API | VERIFIED | `/inventory/zones`, `/inventory/shelves`, shelf↔product map CRUD; `GET /inventory/shelves/{shelf_id}/products` enriches each map row with `product_name`/`sku`/`barcode`; duplicate zone/shelf code → 409; cross-tenant & cross-store reads → 404 |
| Stock API | VERIFIED | `/inventory/stock` list + `/stock/summary`; opening stock single-apply (double-open → 409; concurrent race → exactly one 201, rest 409); adjustment atomic via `SELECT … FOR UPDATE` + `inventory.version` bump + ledger row + audit; **delta-based adjustment** (`delta` OR `new_quantity`, exactly one required) — additive under the row lock so concurrent stock-in/out never lose updates; `delta == 0` → 422; negative result → 422 |
| Expiry API | VERIFIED | `/inventory/expiry` CRUD; batch stock-in moves inventory; status `normal/near_expiry/expired` from `near_expiry_days=30` (new `Settings` knob); FEFO order; delete rejected while `quantity > 0`; adjustment-with-`expiry_batch_id` drains the batch (overdrain → 422) |
| Movements ledger | VERIFIED | `/inventory/movements` paged; `OPENING`/`ADJUSTMENT` with `resulting_quantity` + actor name |
| Stock status | VERIFIED | `healthy`/`low_stock`/`out_of_stock` vs `reorder_point`; summary totals + near-expiry/expired counts |
| Tests | VERIFIED | `pytest` → **45 passed** (15 inventory tests + concurrency delta test +10/+20→130 with exactly 2 version bumps/ADJUSTMENT rows + delta-validation cases + RBAC boundary suite). **2026-08-12 fix:** the concurrent-opening test asserted a *global* count of `OPENING` movements, which breaks once any other live E2E run creates an opening on the shared dev DB — now scoped to `(store_id, product_id, movement_type)`. |

Recorded decisions / deviations (kept deliberately):
- Stock list + summary compute `stock_status`/`value` **in Python per store row** (paged/filtered in memory). Fine at store scale; defer to SQL views at M5 (§6. Reporting).
- Legacy `inventory.view`/`inventory.update` codes (seeded in 0002) remain in the catalog but are **unused**; the four granular codes from 0004 are authoritative for the router.
- Opening-stock idempotency = existence of an `OPENING` movement; the race is closed by `uq_inventory_store_product` + `IntegrityError → 409`.
- `expiry_batches.quantity` is decremented only via adjustment with `expiry_batch_id` (ledger-consistent); deleting a batch is a metadata op, guarded to `quantity == 0`.

---

## [M3_INVENTORY_STATUS] — memory ledger update, verified 2026-08-12

**M3 executed = the Inventory feature** (backend delta-based adjustment + full Flutter inventory UI + live E2E), per the working plan. This is a deliberate scope note: the `[MILESTONES]` table still labels M3 as POS (sequential milestone), and POS remains unimplemented — the mobile inventory feature shipped first because the backend inventory domain (M2) was already complete. The POS milestone is unchanged and still pending.

| Item | Status | Evidence |
|---|---|---|
| Delta-based adjustment (backend) | VERIFIED | `PATCH /inventory/stock/{product_id}` accepts `new_quantity` **or** `delta` (exactly one; `delta==0` → 422); concurrent `+10` and `+20` on 100 serialize to 130 under `FOR UPDATE` with exactly 2 version bumps and 2 ADJUSTMENT ledger rows (test `test_concurrent_adjustments_serialize`). `tests/test_inventory.py` = 18 tests, all passing. |
| Shelf-products endpoint (backend) | VERIFIED | `GET /inventory/shelves/{shelf_id}/products` returns `list[ShelfProductMapOut]` enriched with `product_name`/`sku`/`barcode` (added to `app/routers/inventory.py`). |
| Flutter inventory data layer | VERIFIED | `features/inventory/data/inventory_models.dart` (StockSummary, StockItem, ProductStock, StockMovement, Zone, Shelf, ShelfProductMap, ExpiryBatch, MovementType, StockStatus) + `inventory_api.dart` (store-scoped client, date/quantity quantization). |
| Flutter inventory screens | VERIFIED | 13 screens in `features/inventory/presentation/`: overview, stock detail, opening stock, stock adjust, movements, zones list/detail, shelves list/detail, product picker, expiry list/form/detail. Adjust screen computes live resulting quantity (Current + Adjustment) and requires a reason; opening screen posts `/stock/{id}/opening`. |
| App shell integration | VERIFIED | `app_shell.dart` tab build signature refactored to `Widget Function(SessionController, ApiClient)`; Inventory tab added, RBAC-gated by `inventory.view`; each tab builds its own CatalogApi/InventoryApi from the shared ApiClient. `Icons.shelves` does not exist → `Icons.storefront_outlined`. |
| Permission gates (mobile) | VERIFIED | `core/permissions.dart`: `inventoryView`, `inventoryAdjust`, `inventoryLayout`, `inventoryMovements`, `inventoryExpiry`; UI actions hidden without the matching permission. |
| Widget tests | VERIFIED | `test/inventory_test.dart` — 6 tests: tab renders summary + list, low-stock filter, tab hidden without `inventory.view`, adjust delta flow (signed delta → resulting quantity → PATCH), no-adjust-permission hides actions, opening flow posts + refreshes. |
| Live E2E (Flutter→FastAPI→PG) | VERIFIED | `test/live_inventory_test.dart` — 4 tests, run twice back-to-back (idempotent): stock flow (ensure product → opening once → delta-normalize to 10 → list/summary/detail → movements), layout flow (zone/shelf/mapping both directions + enriched map fields), expiry flow (create → detail → edit → drain via adjustment → delete), RBAC boundary (inv-viewer reads 200; adjust/opening/movements/layout/expiry mutations 403 FORBIDDEN). Run with `flutter test --dart-define=LIVE_API=true --dart-define=API_BASE_URL=http://127.0.0.1:8000 test/live_inventory_test.dart`. |
| RBAC provisioning script | VERIFIED | `scripts/provision_rbac_inventory_viewer.py` — creates system role `inv_viewer` (only `inventory.view`) + user `inv-viewer@acme.com` / `Test1234!`, store-scoped grant to Downtown. Idempotent. Mirrors `provision_rbac_viewer.py` (role `viewer`, `products.view` only). |
| Flutter model bug fixes caught by live E2E | VERIFIED | `ShelfRef` was parsing `shelf_id`/`shelf_label` keys, but the backend embeds `ShelfWithZoneOut` (`id`/`label`/`code`/`zone_name`) in stock detail → `fromJson` remapped. `InventoryApi.updateExpiryBatch` sent raw `DateTime` in the JSON body → now serialized via the existing `_date()` helper. |
| Full regression | VERIFIED | Backend `pytest` → **45 passed** · `ruff check .` → clean · `flutter analyze` → No issues found · `flutter test` → **17 passed** (incl. 6 inventory widget tests). |

Recorded decisions / deviations (kept deliberately):
- Inventory mobile feature shipped ahead of the `[MILESTONES]` M3=POS line (scope note above). POS work has not started.
- Live inventory tests are **deterministic and idempotent**: fixed SKU/zone/shelf/batch codes, product quantity normalized to a fixed target via delta each run, single expiry batch drained+deleted as cleanup, no `DELETE` endpoints used on catalog rows (products/zones/shelves are reused, never duplicated).
- Live inventory tests run against the shared dev DB (`acme` tenant); they deliberately leave the deterministic product/zone/shelf rows present between runs.
- The backend pytest suite shares the same dev DB (per `tests/conftest.py`, tenants are created/cleaned per test but the DB is not dropped). Live E2E runs create durable rows on the `acme` tenant — keep test assertions scoped to their own tenant/store/product.

---

## [M4_STATUS] — decision record, approved 2026-08-13

**M4 is split into two tracks. M4-B (real AI/YOLO) remains BLOCKED; M4-A (AI business/domain foundation) is NOT blocked and is approved for implementation.**

| Track | Scope | Status |
|---|---|---|
| **M4-A** | AI domain foundation on `MockAIVisionPort`: scan session → detections → aggregation → reconciliation → explicit confirmation → COUNT movement → audit. No torch/ultralytics. | **APPROVED / IN PROGRESS** — **M4-A.1 DONE (verified 2026-08-13)** · **M4-A.2 DONE (verified 2026-08-13)** · **M4-A.3 DONE (verified 2026-08-13)** · **M4-A.4 DONE (verified 2026-08-13)** · **M4-A.5 HTTP API + RBAC DONE (verified 2026-08-13, see `[M4_A5_STATUS]`)** · **M4-A.6 Flutter AI Count client DONE (verified 2026-08-13, see `[M4_A6_STATUS]`)** · **M4-A.7 Review decisions override/ignore DONE (verified 2026-08-15)** |
| **M4-B** | Real vision inference (YOLO adapter behind `AIVisionPort`) | **BLOCKED** |

**M4-A.1 — AI vision domain database/models (VERIFIED 2026-08-13):**
- Migration `0005_ai_vision_schema` APPLIED (head = 0005; downgrade→upgrade cycle verified clean). New tables:
  - `scan_sessions` — status `processing/needs_review/confirmed/cancelled/completed/failed`, optional `shelf_id`, `image_count`, `started_by/completed_by`, `completed_at`.
  - `scan_detections` — `method` (`barcode/visual/ocr/manual`), `detected_sku/barcode`, optional `product_id`, `confidence` (`Numeric(5,4)`, NULL-able for manual), `quantity_detected > 0` CHECK, `status` (`accepted/needs_review`), JSONB `meta`. Per-detection row; aggregation happens in the service layer (M4-A.3).
  - `scan_reconciliations` — `detected_quantity` vs `system_quantity` vs `variance`, `status` (`no_change/needs_review/applied`), `resolution` (`apply/ignore`), `confirmed_by/confirmed_at`, `UNIQUE(session_id, product_id)`.
  - Every table carries `tenant_id`/`store_id` FK CASCADE + tenant/store indexes (structural scoping per Protocol 3).
- Permissions seeded to owner+admin: `ai.scan`, `ai.reconcile`, `ai.confirm`, `ai.view` (mirrors 0004 seeding; ON CONFLICT idempotent).
- Models in `app/models/ai.py` (ScanSession/ScanDetection/ScanReconciliation), schemas in `app/schemas/ai.py` (ScanStatus/DetectionMethod/DetectionStatus/ReconciliationStatus/ReconciliationResolution + In/Out), exported via `app/models/__init__.py` + `app/schemas/__init__.py`.
- Tests: `tests/test_ai.py` = 4 tests (roundtrip + FK cascade-delete, quantity>0 CHECK, confidence range CHECK, unique session+product reconciliation) — **all passing**. Full suite **49 passed**, `ruff check .` clean. `tests/test_auth.py` `OWNER_PERMISSIONS` updated to include the four new `ai.*` codes.

**M4-A.2 — AIVisionPort protocol + deterministic MockAIVisionPort (VERIFIED 2026-08-13):**
- New package `app/ai/` (code adapter; the repo-root `ai/` dir stays a data/artifacts scaffold and is NOT a Python package):
  - `app/ai/contract.py` — typed, immutable contract: `VisionContext` (tenant_id/store_id/shelf_id) + `DetectedItem` (method `barcode/visual/ocr/manual`, detected_sku/barcode, confidence `Decimal` 0..1 (None only for manual), quantity > 0, meta JSON-able). Cross-field rule enforced: machine methods require confidence; manual must not carry one.
  - `app/ai/vision_port.py` — `AIVisionPort` Protocol (`@runtime_checkable`, async `analyze_image(image, context) -> list[DetectedItem]`). Pure function of inputs: no session, no DB, no inventory access — inventory mutation is structurally impossible from an adapter.
  - `app/ai/mock_vision.py` — `MockAIVisionPort` + `MockImagePayload` + `encode_mock_image()`. Deterministic byte contract `b"VS-MOCK-1\n" + JSON`. Any non-conforming input (empty/garbage/bad magic/malformed/invalid items) deterministically yields ONE fallback detection: `visual, confidence 0.40, quantity 1, no sku/barcode` — the needs-review gate stays in the service layer (M4-A.3).
  - `app/ai/__init__.py` — composition root `get_vision_port() -> AIVisionPort` (only place naming the concrete adapter; M4-B swaps here without touching the business layer).
- The adapter is pure perception: it never resolves `product_id` (sku/barcode → product matching is tenant/store-scoped business logic in M4-A.3) and never touches inventory.
- No new dependencies: stdlib `json` + existing `pydantic` only. No torch/ultralytics/AI runtime added; `pyproject.toml` unchanged.
- Tests: `tests/test_vision_port.py` = 8 tests (protocol wiring via `isinstance`, deterministic decode + repeat-call equality, item order preserved, fallback on 6 non-conforming inputs, fallback on 3 invalid-item payloads, contract confidence rules, out-of-range rejection, and **adapter-never-mutates-inventory** proven against a live seeded product + opening stock). **All passing**.
- Full regression: `pytest` → **57 passed** (49 prior + 8 new), `ruff check .` → clean → M1–M3 behavior preserved.

**M4-A.3 — Scan Service Lifecycle (VERIFIED 2026-08-13):**
- New `app/services/ai_service.py`: `create_scan_session` (store+shelf tenant/store-validated, status `processing`) and `process_scan` (locked `FOR UPDATE` session → injected `AIVisionPort` → tenant/store-scoped product resolution → persist detections → deterministic keyed Decimal aggregation → reconciliation vs `inventory.quantity` → `completed` | `needs_review`; vision failure → persisted `failed` + `ScanProcessingFailed`).
- **Status vocabulary alignment (A.1 refinement):** the A.3 lifecycle mandates `processing/completed/needs_review/failed`; the A.1 placeholder `active` was replaced. `SCAN_STATUSES` + `ScanStatus` Literal updated, model default → `processing`, migration `0006_scan_status_default` updates the DB server_default (downgrade→upgrade cycle verified). Tables were empty, so no data migration.
- **NON-NEGOTIABLES satisfied:** (1) service imports `AIVisionPort` protocol only — `MockAIVisionPort` is never referenced in business code (enforced by a source-inspection test); (2) product resolution scoped to `(tenant_id, store_id)`, barcode-first then SKU, via `normalize_barcode`; (3) shelf validated against tenant+store at session creation; (4) **zero inventory mutation and zero `StockMovement` writes during scanning** — reads `inventory.quantity` only; the sole stock write path is explicit confirmation (M4-A.4); (5) one centralized configurable threshold `Settings.ai_confidence_threshold = 0.70` (`AI_CONFIDENCE_THRESHOLD` env) — machine detections below it (and any unresolvable product) force the session to `needs_review`; (6) aggregation keyed by product with exact Decimal sums (item order never changes totals); (7) duplicate processing guarded by `FOR UPDATE` + `processing`-only check → second call 409, exactly one detection/reconciliation set; (8) vision exceptions → deterministic `failed` state persisted; (9) images are never persisted and never logged (no `image_key` content, no image bytes stored).
- Scan images are not stored anywhere; `DetectedItem.meta` may hold OCR payloads but nothing sensitive is logged.
- Tests: `tests/test_scan_service.py` = 16 tests covering every required scenario: successful lifecycle (incl. context passed to port, reconciliation variance), tenant isolation (404, port never called), store isolation (404 + valid second store), shelf isolation (404), product-resolution isolation (same barcode across tenants resolves to own product), SKU resolution, barcode resolution, unknown product → needs_review + no reconciliation, threshold boundary (0.69 → review / 0.70 → accepted), low-confidence → needs_review, deterministic aggregation (item order swapped → identical totals), duplicate processing → 409 + no duplicate rows, failed processing → `failed` + no detections/reconciliations + inventory untouched, zero inventory mutation, zero stock movement, protocol-only dependency (source inspection) + fake port satisfies `AIVisionPort`. **All passing**.
- Full regression: `pytest` → **73 passed** (57 prior + 16 new), `ruff check .` → clean → **M1–M3 suite remains green**.

**M4-A.4 — Explicit Scan Confirmation (VERIFIED 2026-08-13):**
- New `confirm_scan_session` in `app/services/ai_service.py` — the ONLY stock-write path from a scan. ONE atomic DB transaction: session row locked `FOR UPDATE` → status must be `completed`/`needs_review` (PROCESSING/FAILED/CANCELLED/already-CONFIRMED → 409) → reconciliations loaded scoped + ordered by product_id → affected inventory rows locked in deterministic product order → each reconciliation's recorded `system_quantity` re-checked against the locked current quantity (stale scan → 409, nothing written) → apply detected quantity + bump `inventory.version` + one `COUNT` StockMovement (`reference_type=SCAN_SESSION`, `reference_id=session_id`) per affected product → reconciliation marked `applied`/`apply`/`confirmed_by`/`confirmed_at` → session `confirmed` → audit `scan_confirmed` → commit. Zero-variance reconciliations are marked applied without a movement; `resolution="ignore"` reconciliations are skipped. Any failure (AppError / IntegrityError / unexpected) → `db.rollback()` + re-raise. Duplicate confirmation → 409 (CONFIRMED ∉ confirmable statuses; the session row lock serializes concurrent confirmations). Cross-tenant / cross-store → 404.
- Migration `0007_scan_count_unique` APPLIED (head = 0007; downgrade→upgrade cycle verified clean): partial unique index `uq_stock_movements_scan_count` on `stock_movements(store_id, product_id, reference_id)` WHERE `movement_type='COUNT' AND reference_type='SCAN_SESSION'` — "no duplicate movement" as a DB invariant; existing OPENING/ADJUSTMENT/EXPIRY_BATCH rows untouched (M1–M3 concurrency semantics preserved).
- Concurrency semantics reused from M2/M3: `FOR UPDATE` row locks (session + inventory), monotonic `inventory.version` bump on every write, additive-delta movement ledger, audit row. No AIVisionPort change, no torch/ultralytics, no router (per approved scope).
- Tests: `tests/test_confirm_scan.py` = **17 tests** (14 required: success · correct signed delta · exactly one COUNT per affected product · audit created · complete rollback on failure · duplicate 409 · concurrent no-double-apply (exactly one 200 + one 409, version bumped exactly once) · stale inventory rejected safely · FAILED 409 · CANCELLED 409 · cross-tenant 404 · cross-store 404 · NEEDS_REVIEW requires explicit confirmation · no duplicate movement; + 3 extra: PROCESSING 409, zero-variance marks applied without movement, count establishes stock when no inventory row exists). **All passing**.
- Full regression: `pytest` → **90 passed** (73 prior + 17 new), `ruff check .` → clean → M1–M3 suite remains green. `alembic current` → `0007 (head)`.

**M4-A.6 — Flutter AI Count client (VERIFIED 2026-08-13):**
- New `apps/mobile/lib/features/ai/` feature wiring the six `/ai` endpoints into the inventory overview. Data layer: `data/ai_models.dart` (ScanSession / ScanDetection / ScanReconciliation mirroring the backend schemas + display metadata + the 9-state `AiScanUiState` machine) and `data/ai_api.dart` (typed, store-scoped client — create/process/get/detections/reconciliations/confirm — with the backend error envelope surfacing as typed `ApiException`).
- Acquisition boundary: `data/mock_scan_image.dart` — `ScanImageSource` protocol + `MockScanImageSource` (deterministic scenes: matched barcode @0.98, low-confidence visual @0.45, unknown-item) emitting the exact `VS-MOCK-1\n` byte contract. **Contract bug found & fixed:** the Flutter `DetectedItem` JSON used `quantity_detected`, but the backend mock decodes `quantity` → aligned with `app/ai/mock_vision.py`. M4-B swaps in a camera source at this boundary without touching the wizard.
- Screen: `presentation/ai_count_screen.dart` — 3-step wizard (zone → shelf → image) → create → process → results (detections + reconciliation metrics) → explicit confirm dialog → success → pops `true` so the inventory overview reloads. Permission-gated at every surface: `ai.scan` gates the wizard entry, `ai.view` the results, `ai.reconcile` the variance rows/banner, `ai.confirm` the confirm button (with a permission-note card when absent). Processing/failed/network/backend-error states with Retry branching.
- Wiring: `features/inventory/presentation/inventory_overview_screen.dart` — "AI Count" action (`TextButton.icon`) gated on `ai.scan` + a selected store; on confirmed completion the overview reloads.
- Tests: `test/ai_count_test.dart` = **17 tests** (2 byte-contract units + 15 widget: permission gates, wizard step advance, create/process wire contract incl. gate-gated processing spinner, results + reconciliation rendering, needs-review banner, confirm permission, explicit-confirm flow that pops with `true`, duplicate 409 snackbar, failed/network/403/404 error paths). `test/live_ai_test.dart` = **3 live E2E** (full lifecycle, unknown-session 404, RBAC boundary incl. `ai.reconcile`/`ai.scan`/`ai.confirm` 403s) — skipped unless `--dart-define=LIVE_API=true`.
- Full regression: `flutter analyze` → **No issues found!** · `flutter test` → **34 passed, 16 skipped (live), 0 failures** — M1/M2.1/M3 suites remain green. No new dependencies.

**M4-A.7 — Review decisions: override / ignore (VERIFIED 2026-08-15):**
- Closes the A10 P1 gap — the `needs_review` reconciliation state is now actionable. New `PATCH /ai/scans/{session_id}/reconciliations/{reconciliation_id}` (permission `ai.reconcile`): body `{"resolution": "apply"}`, `{"resolution": "ignore"}`, or `{"resolution": "apply", "detected_quantity": <n>}`. New `ReconciliationUpdate` schema (`detected_quantity` `Decimal ge=0`, `max_digits=12`, `decimal_places=3`, `model_validator` rejects quantity with `ignore`; oversized/non-numeric decimals → 422). New `update_reconciliation` in `app/services/ai_service.py` — session + reconciliation both `FOR UPDATE` and tenant/store/session-scoped (wrong scan/tenant/store → 404), state gate (only `completed`/`needs_review`, else 409), `ignore` = no inventory mutation, override recomputes `variance`/`status` against the reviewed quantity, audit `reconciliation_updated` (before/after), single transaction.
- **Read/write permission split:** `GET /ai/scans/{id}/reconciliations` gate relaxed from `ai.reconcile` → `ai.view` so non-reconcilers see read-only rows; mutation stays `ai.reconcile` (repo `*_view` read pattern).
- Mobile: `AiCountScreen` needs_review rows gain **Override quantity** (quantity editor, non-negative client validation) and **Ignore** controls; badges Ignored/Overridden/status; confirm summary (`X product(s) to apply · Y ignored · Z overridden`); confirm dialog notes ignored products are untouched; success screen counts only non-ignored rows as affected; without `ai.reconcile` rows render read-only and `ai.confirm` stays independently gated. Confirm safety (FOR UPDATE, deterministic inventory locking, stale system_quantity re-check, duplicate COUNT protection, atomicity, audit) is untouched.
- Tests: backend `tests/test_review_scan.py` = **22 tests** (apply · ignore-no-mutation · override recompute · negative/oversized-precision/non-numeric/invalid-resolution/ignore+quantity → 422 · missing `ai.reconcile` → 403 · ai.view read OK + PATCH 403 · cross-tenant 404 · cross-store 404 · reconciliation-of-another-scan 404 · unknown id 404 · override-as-COUNT-target · override-to-zero · double-confirm 409 · stale-inventory 409 · atomic rollback · audit decision · processing 409 · confirmed 409). Mobile `test/ai_count_test.dart` grew to **26 tests** (+9 review widgets). Full suites: backend **142 passed**, `ruff check .` clean; mobile **131 passed / 16 skipped (live) / 0 failures**, `flutter analyze` clean. No new dependencies, no migrations, no new permissions.

**M4-A regression checklist (additive; tracked here until run):**
- [x] **Fresh-database migration-chain verification** — full `alembic upgrade head` (0001 → 0007) on a brand-new empty database (M0 DoD already requires migrations re-runnable on clean env; M4-A.1/0005 + 0006 + 0007 must be part of that chain proof). Does NOT block M4-A.4 or M4-A.5. **DONE 2026-08-16 as A11 — automated in `tests/test_migrations.py` (scratch DB, created/dropped per run).**
- [x] **Service-layer E2E chain** (M4-A.4 test suite): mock image → session → detections → aggregation → reconciliation → confirm → COUNT movement → audit log — covered end-to-end at the service layer.
- [x] **Router-level RBAC boundaries** for `ai.scan/reconcile/confirm/view` — DONE 2026-08-13 as M4-A.5 (see `[M4_A5_STATUS]`).

**M4-B hard blockers (unchanged):**
1. **M2.5** real dataset / store onboarding (see `[ORPHANS & PENDING]`).
2. **AI runtime/model dependency decision** — torch/ultralytics are not installed (`services/api/.venv`, Python 3.13.15) and no model artifact exists; installing them is deferred until M4-B is unblocked. **Confirm torch has compatible cp313 Windows wheels before locking versions. Development venv: Python 3.13.15.**
3. **Ultralytics AGPL-3.0 license review** (commercial SaaS) — pending legal decision.

**Android is NOT an M4 hard blocker:** SDK 36 verified · ADB verified · physical Samsung A15 verified · host→backend network (`192.168.1.2:8000`) verified · APK build is still pending final success (`[M0_VERIFICATION]`). M4-A does not wait on the APK build.

---

## [M4_A5_STATUS] — HTTP API + RBAC, verified 2026-08-13

**M4-A.5 DONE (backend).** The M4-A service-layer capabilities are now exposed through a thin HTTP router (`app/routers/ai.py`) with the seeded RBAC permissions. No inventory logic, no AI logic and no direct DB-mutation logic in the router — every write delegates to `app.services.ai_service` (`create_scan_session` / `process_scan` / `confirm_scan_session`); the vision adapter is injected via `get_vision_port_dependency` (composition root → `app.ai.get_vision_port`), overridable for tests. Router registered in `app/main.py` (`/ai`).

### API contract

All endpoints use the existing envelope: success = typed schema body; error = `{"detail": {"code", "message", "details?}}` with the standard status semantics (401 UNAUTHORIZED / SESSION_EXPIRED / DEVICE_REVOKED / ACCOUNT_DISABLED · 403 FORBIDDEN · 404 NOT_FOUND · 409 CONFLICT · 422 VALIDATION_ERROR · 500 INTERNAL_ERROR). `store_id` is a required query parameter on every endpoint; tenant/store ownership comes from the token + auth chain, never from the client. Cross-tenant / cross-store / foreign-shelf → **404** (existence never leaked).

| METHOD | PATH | AUTH | PERMISSION | REQUEST | RESPONSE | ERRORS |
|---|---|---|---|---|---|---|
| `POST` | `/ai/scans` | Bearer JWT → account → device → tenant → store | `ai.scan` | `store_id` query + JSON `{shelf_id? (uuid), note? (≤500)}` | `201 ScanSessionOut` (`status=processing`) | 401 · 403 · 404 (store/shelf) · 422 |
| `POST` | `/ai/scans/{session_id}/process` | same chain | `ai.scan` | `store_id` query + raw image bytes in body (≤20 MB; mock contract `VS-MOCK-1\n` + JSON, see `app/ai/mock_vision.py`) | `200 ScanSessionOut` (`completed` / `needs_review` / `failed`) | 401 · 403 · 404 (session) · 409 (not `processing`) · 422 (oversized) · 500 (vision failure → session persisted `failed`) |
| `GET` | `/ai/scans/{session_id}` | same chain | `ai.view` | `store_id` query | `200 ScanSessionOut` (status/results) | 401 · 403 · 404 |
| `GET` | `/ai/scans/{session_id}/detections` | same chain | `ai.view` | `store_id` query | `200 list[DetectionOut]` | 401 · 403 · 404 |
| `GET` | `/ai/scans/{session_id}/reconciliations` | same chain | `ai.reconcile` | `store_id` query | `200 list[ReconciliationOut]` (with `product_name`/`sku`) | 401 · 403 · 404 |
| `POST` | `/ai/scans/{session_id}/confirm` | same chain | `ai.confirm` | `store_id` query | `200 ScanSessionOut` (`confirmed`); applies reconciled counts as COUNT movements + audit | 401 · 403 · 404 · 409 (PROCESSING / FAILED / CANCELLED / already-CONFIRMED / stale inventory) |

### RBAC matrix

| Permission | Endpoint(s) |
|---|---|
| `ai.scan` | `POST /ai/scans`, `POST /ai/scans/{id}/process` |
| `ai.view` | `GET /ai/scans/{id}`, `GET /ai/scans/{id}/detections` |
| `ai.view` | `GET /ai/scans/{id}`, `GET /ai/scans/{id}/detections`, `GET /ai/scans/{id}/reconciliations` *(read; reconciliation reads relaxed from `ai.reconcile` in M4-A.7 — see `[M4_A11]`)* |
| `ai.reconcile` | `PATCH /ai/scans/{id}/reconciliations/{rid}` *(added in M4-A.7; the A.5-era `GET` placement is superseded)* |
| `ai.confirm` | `POST /ai/scans/{id}/confirm` |

No permission was broadened: only the four permissions seeded in migration `0005` are used, one per endpoint. `ai.reconcile` was placed on the reconciliation listing (the only review surface in the existing service layer); a future explicit reconcile-override endpoint will reuse it without granting anything new. **Supersession note (M4-A.7, recorded additively):** the override/ignore endpoint exists — `PATCH /ai/scans/{id}/reconciliations/{rid}`, permission `ai.reconcile`; reconciliation reads now require `ai.view` (repo read-permission pattern), see `[M4_A11]`.

### Non-negotiable compliance (unchanged through HTTP)

- Scan **processing never mutates inventory and writes no StockMovement rows** — the sole stock-write path is explicit `confirm` (verified at HTTP level: process → inventory unchanged, zero movements).
- **Images are never persisted and never logged** (only in-memory bytes in the process call; 20 MB cap).
- Duplicate/FAILED/CANCELLED/PROCESSING confirmation → 409; stale inventory → 409; exactly one COUNT movement per (store, product, session) enforced by `uq_stock_movements_scan_count`.
- Audit row `scan_confirmed` written on confirmation; owner + admin carry all four `ai.*` grants (verified on fresh DB).

### M4-A.5 regression checklist (all run)

- [x] Fresh-DB migration chain `0001 → 0007` from scratch (disposable DB, dropped after) — tables, indexes, 4 permissions, owner+admin grants, partial unique index all present; `alembic current` → `0007 (head)`.
- [x] Service-layer E2E chain (M4-A.4 suite) — still green.
- [x] Router-level RBAC boundaries — 24 HTTP tests (see `[ORPHANS & PENDING]` M4-A.5 row).
- [x] Full regression: `pytest` → **114 passed** (90 prior + 24 new), `ruff check .` clean → M1–M3 behavior preserved.

---

## [M4_A6_STATUS] — Flutter AI Count client, verified 2026-08-13

**M4-A.6 DONE (mobile).** The M4-A scan lifecycle is now usable from the Flutter client: a permission-gated AI Count entry on the Inventory overview opens a 3-step wizard (zone → shelf → image) that creates a scan, processes mock image bytes, renders detections + reconciliation metrics, and applies counts through an explicit confirmation dialog. The vision-adapter seam mirrors the backend composition root: `ScanImageSource` is the acquisition boundary, and `MockScanImageSource` (M4-A deterministic scenes) is the only concrete source — M4-B replaces it with a camera source without touching the wizard.

### API surface consumed (all store-scoped via token, `store_id` query param)

| Flutter call | HTTP | Permission |
|---|---|---|
| `AiApi.createScan` | `POST /ai/scans` | `ai.scan` |
| `AiApi.processScan` (raw bytes) | `POST /ai/scans/{id}/process` | `ai.scan` |
| `AiApi.getScan` | `GET /ai/scans/{id}` | `ai.view` |
| `AiApi.getDetections` | `GET /ai/scans/{id}/detections` | `ai.view` |
| `AiApi.getReconciliations` | `GET /ai/scans/{id}/reconciliations` | `ai.view` *(reads relaxed from `ai.reconcile` in M4-A.7; the PATCH review endpoint is `ai.reconcile` — see `[M4_A11]`)* |
| `AiApi.confirmScan` | `POST /ai/scans/{id}/confirm` | `ai.confirm` |

### UI permission gates (every surface)

- Wizard entry (Inventory overview "AI Count"): `ai.scan` + selected store. Without it the overview hides the action.
- Results + detections: `ai.view`; reconciliation metrics: `ai.reconcile`; confirm button: `ai.confirm` (absent permission → note card, no button).
- Confirm is only reachable for `completed`/`needs_review`; a 409 (duplicate/stale) surfaces the backend message via snackbar and the session stays on results; a backend `failed` session → failed state + Retry.

### Error/UX behavior

- Typed `ApiException` from the backend envelope → the `message` is shown; transport failures → friendly "Cannot reach the server." string.
- Scan failure, missing permissions, 403/404/409, and network errors are all covered by widget tests.

### Test evidence (all executed)

- `flutter analyze` → **No issues found!**
- `flutter test` → **34 passed, 16 skipped (live), 0 failures** — includes the 17 new AI tests; M1/M2.1/M3 suites unaffected.
- `test/live_ai_test.dart` (3 tests) is live-opt-in (`--dart-define=LIVE_API=true --dart-define=API_BASE_URL=http://127.0.0.1:8000`), deterministic/idempotent fixtures (`M4-QA-PROD-001` / `M4-QA-ZONE` / `M4-QA-SHELF`), covers happy lifecycle, unknown-session 404, and the `ai.view`-only RBAC boundary. Requires a provisioned `ai-viewer@acme.com` (only `ai.view`) via `scripts/provision_rbac_ai_viewer.py`.

### Unverified / deferred

- Live E2E suite not executed this session (needs Uvicorn + Postgres running; the running 13 live tests that exercised M1–M3 earlier were skipped here too).
- APK build + on-device execution remain pending final success (`[M0_VERIFICATION]`) — the Flutter implementation is analyze/test-verified; physical-device execution is not yet proven for the AI Count flow.

---

## [A8_WRITE_OFF] — Expired-stock write-off (ledger + API + Flutter UI), verified 2026-08-14

**A8 DONE.** Expired stock can now be removed from inventory with a first-class `WRITE_OFF` ledger movement referencing the expiry batch — fixing the M3 gap where the only way to clear an expired batch was a manual adjustment. No DB migration (movement_type is a free string; the seeded `inventory.manage_expiry` permission is reused — no new permission, no schema change).

### Backend

- Vocabulary: `WRITE_OFF` added to `app/models/inventory.py` `MOVEMENT_TYPES` and `app/schemas/inventory.py` `MovementType` Literal. New `ExpiryBatchWriteOffIn` (`quantity: Decimal(gt=0, max_digits=12, decimal_places=3)`, `reason: str(1..500)`), exported via `app/schemas/__init__.py`.
- Service `write_off_expiry_batch` (`app/services/inventory_service.py`): tenant+store-scoped batch lookup (missing → 404), **expired-only** (`expiry_date >= today` → 422), `qty ≤ batch.quantity` (422), inventory row locked `FOR UPDATE` (missing → 404, `qty ≤ inventory.quantity` → 422), batch + inventory decremented, `inventory.version += 1`, one `WRITE_OFF` StockMovement (`reference_type=EXPIRY_BATCH`, `reference_id=batch_id`, negative `quantity_delta`, `resulting_quantity`, `notes=reason`), audit `expiry_batch_written_off` — single transaction. Whitespace-only reason rejected at the service layer (422), not just pydantic.
- Route `POST /inventory/expiry/{batch_id}/write-off` (`app/routers/inventory.py`), permission `inventory.manage_expiry`, `store_id` from query but tenant/store ownership always from token chain; returns updated `ExpiryBatchOut`.
- Tests (`tests/test_inventory.py`, now 21 tests): happy path (10 → write off 6 → batch/stock `4.000`, WRITE_OFF row assertions, full drain → delete allowed); validation (non-expired / qty>remaining / qty 0 / blank reason / overdraft → 422); RBAC (write-off 403 for `inventory.view`-only viewer in the boundary suite); cross-store isolation (other store's id → 404 NOT_FOUND). Full backend regression: `pytest` → **117 passed** · `ruff check` clean.

### Mobile

- `InventoryApi.writeOffExpiryBatch` (`features/inventory/data/inventory_api.dart`) → `POST /inventory/expiry/{batch_id}/write-off` with quantized quantity + reason.
- Expiry batch detail (`expiry_batch_detail_screen.dart`): **Write off stock** button only when `manage_expiry` && `isExpired` && `quantity > 0`. Dialog prefills quantity with the full batch amount (via `AppFormat.qty`), requires a non-empty reason, and validates quantity > 0 and ≤ available. Success → 'Stock written off' snackbar + reload; a drained batch then enables Delete. Reason required at the UI too.
- Movements screen: **Write offs** filter chip → `MovementType.writeOff` (`WRITE_OFF`).
- Widget tests (`test/inventory_layout_test.dart`, now 34 tests): mock seeded with expired `Yogurt 500g` batch (LOT-C, 8.000) + a `POST .../write-off` handler with request-body recorder; write-off flow (prefilled qty 8, reason, body asserted, '0 in batch', Delete enabled), validation (blank reason / over-available / zero), gating (no button on normal or drained batches), hidden-without-`manage_expiry`, and the movements chip request (`WRITE_OFF` → empty state).
- Full mobile regression: `flutter analyze` → **No issues found!** · `dart format` → 0 changed · `flutter test` → **113 passed, 16 skipped (live), 0 failures** (was 109 passed).

### Unverified / deferred

- Live Flutter E2E for write-off (`test/live_inventory_test.dart`) not extended this session (needs Uvicorn + Postgres running; the live-gated 16 are skipped). Backend pytest DID run against the live local Postgres (117 passed).
- No changes to `MILESTONES`/`ORPHANS & PENDING`: write-off is recorded here as an executed improvement inside the already-shipped Inventory domain.

---

## [M4_A11] — Production-readiness close-out, verified 2026-08-16

**A11 DONE.** Read-only audit (2026-08-16) confirmed A11.1–A11.3 invariants already hold in the shipped code — the single stock-write path is explicit `confirm` (PATCH review mutates review state only), RBAC is server-authoritative per endpoint, and tenant/store scoping is structural (`require_store` + service-level scoping) — and found **two P1 gaps**, both closed here: **(1)** no automated fresh-DB migration-chain proof, **(2)** the live review (PATCH) E2E had zero coverage and one stale RBAC assertion. No `app/` code (routers/services/schemas/models) changed in A11 — the fixes are tests + a missing provisioning script + one mobile UX note.

### Backend (cwd `services/api`)

- New `scripts/provision_rbac_ai_viewer.py` (idempotent, mirrors the existing viewer provisioners): system `ai_viewer` role holding ONLY `ai.view`, `ai-viewer@acme.com` scoped to acme/Downtown. Was referenced by `test/live_ai_test.dart` but missing from the repo — confirmed gap closed.
- New `tests/test_migrations.py` (1 test): runs `alembic upgrade head` (0001 → 0007) against a **scratch DB created and dropped per run** (superuser DSN derived from `DATABASE_URL`, overridable via `TEST_PG_SUPERUSER_URL` / `TEST_PG_SUPERUSER_PASSWORD`; required because the app role `vs` lacks CREATEDB). Asserts: single head `0007`; all 24 model tables; `scan_sessions.status` server default `'processing'` (0006); `scan_reconciliations` review columns (`resolution`/`confirmed_by`/`confirmed_at`) + `inventory.version`; the four `ai.*` permissions seeded; owner+admin granted all four (8 grants); partial unique index `uq_stock_movements_scan_count` with the `COUNT`/`SCAN_SESSION` predicate (0007). **PASSED** (1/1, ~5 s). Ticks the long-open M4-A regression-checklist item.
- Full regression: `pytest` → **143 passed** (142 prior + 1 new), `ruff check` clean.

### Mobile (cwd `apps/mobile`)

- `test/live_ai_test.dart` (3 → **9 tests**):
  - **Fixed stale RBAC assertion:** `GET /ai/scans/{id}/reconciliations` for `ai.view`-only user now asserted `200` (was asserting 403 — wrong since M4-A.7 relaxed reads); added `PATCH …/reconciliations/{rid}` → 403 for the same user (needs `ai.reconcile`).
  - **Fixed** the unknown-session 404 test to use a well-formed UUID (the literal `'does-not-exist'` is a path-validation 422, not 404 — different contract).
  - **Added 6 live PATCH E2E tests:** apply → confirm → exactly one COUNT movement (`quantity_delta = detected − system`, `resulting_quantity = detected`); ignore → confirm → no COUNT movement + stock unchanged; override → confirm → movement uses the overridden quantity; validation → 422 on negative quantity / unknown resolution / ignore+quantity; isolation → 404 for cross-session reconciliation / unknown reconciliation / unknown session / alien store; confirm is single-shot → second confirm 409. Uses deterministic product `M4-QA-PROD-001`, stock normalized to a fixed quantity before each run.
- `lib/features/ai/presentation/ai_count_screen.dart` minimal UX fix: the Reconciliation section is now gated on `_canReconcile || _canView` (the same condition `_loadResults` uses to fetch rows); users with neither see "Reconciliation results require the ai.view permission." instead of the misleading "No reconciliation rows." Added 1 widget test (`test/ai_count_test.dart`, now **27**).
- Full regression: `dart format` 0 issues · `flutter analyze` → **No issues found!** · `flutter test` → **132 passed, 16 skipped (live), 0 failures**.

### Live E2E (all run, `LIVE_API=true` against `127.0.0.1:8000` + local Postgres 18.6)

- Prerequisites seeded via the repo's own tooling (dev-only): `app.cli create-tenant` (acme + `owner@acme.com`/`Test1234!` + Downtown store) then `scripts.provision_rbac_viewer` / `provision_rbac_inventory_viewer` / `provision_rbac_ai_viewer` (viewer / inv-viewer / ai-viewer).
- `test/live_ai_test.dart` → **9/9 passed** (full scan lifecycle, 404 surface, RBAC read/PATCH boundary, and the six PATCH scenarios).
- Complete live suite → **22/22 passed** (9 AI + 4 inventory + 3 catalog + 6 integration).

### Supersessions / corrections (documented additively; historical entries not rewritten)

- `GET /ai/scans/{id}/reconciliations` is read-gated by **`ai.view`** (relaxed in M4-A.7), not `ai.reconcile`; `PATCH …/reconciliations/{rid}` is **`ai.reconcile`**. The `[M4_A5_STATUS]` RBAC table row and the `[M4_A6_STATUS]` API-surface cell for reconciliation reads are superseded accordingly (inline markers added).
- Remaining documented P2 (unchanged, not A11 scope): CORS `*` placeholder (`app/main.py`, per AGENTS.md), no logging redaction (`app/core/logging.py`), no rate limiting.

---

## [CAMERA_AI_INVENTORY] — First-release sprint: three scan operations (count / receive / sale) + real camera path, verified 2026-08-16

**DONE (as scoped).** The M4-A scan lifecycle is now parametrized into three first-class workflows — **AI Count** (replace, `COUNT`), **AI Stock Receiving** (`+detected`, `PURCHASE`), **AI Quick Sale** (`−detected`, `SALE`) — reusing the existing `COUNT`/`PURCHASE`/`SALE` movement vocabulary and the existing `ai.*` permission set (no new permissions, no new movement types). The wizard gained an operation chooser, and a real-device **camera capture path** (mobile_scanner 7.4.0) was added behind the same `ScanImageSource` boundary. Real inference remains **M4-B BLOCKED**; with the deterministic mock backend a real photo honestly falls back to an unmatched low-confidence detection → `needs_review` (never a silent wrong stock change). Physical-device verification was impossible in this environment (no ADB target) and is documented UNVERIFIED. Release APK built: `apps/mobile/build/app/outputs/flutter-apk/app-release.apk` (67.3 MB).

### Backend (cwd `services/api`)

- `scan_sessions.operation` — `String(10)`, server default `'count'`, `CheckConstraint ck_scan_sessions_operation IN ('count','receive','sale')` (`app/models/ai.py`).
- Migration `migrations/versions/0008_scan_operation.py`: adds the column and **widens the dedup index** from COUNT-only `uq_stock_movements_scan_count` to `uq_stock_movements_scan_session (store_id, product_id, reference_id) WHERE reference_type='SCAN_SESSION'` — the atomic-confirm guard now covers receive/sale movements too. Applied to the local `visionstock` DB (0007 → 0008).
- `app/schemas/ai.py`: `ScanOperation = Literal["count","receive","sale"]`, `ScanSessionCreate.operation` default `"count"`, `ScanSessionOut.operation`.
- `app/services/ai_service.py`: `_variance_for()` (count → detected−system; receive → +detected; sale → −detected); `create_scan_session(operation=...)` + 422 on unknown; `confirm_scan_session` branches — count replaces (`COUNT`), receive adds (`PURCHASE`, `new = system + detected`), sale subtracts (`SALE`, `new = system − detected`); **sale with `new < 0` → 422 `"Insufficient stock for this sale; detected quantity exceeds available stock"` with full atomic rollback** (no movement / audit / reconciliation change). Per-operation movement notes; stale `system_quantity` re-check and `FOR UPDATE` locking unchanged.
- `app/routers/ai.py` passes `body.operation`.
- Tests: new `tests/test_scan_operations.py` (**18 tests**: receive add + PURCHASE + resulting qty; sale subtract + SALE; insufficient-stock 422 + rollback; sale with no inventory row → 422; receive creates inventory when absent; override recomputes ±detected variance; override-to-zero writes no movement; override-to-insufficient rejected; double-confirm 409; DB-level dedup IntegrityError on forged duplicate; cross-tenant 404; HTTP create echoes operation + 422 unknown; HTTP sale confirm). `tests/test_migrations.py` updated to head `0008` + operation default + widened index. Full regression: `pytest` → **161 passed** · `ruff check` clean.

### Mobile (cwd `apps/mobile`)

- `ai_models.dart`: `AiScanOperation` enum (`count`/`receive`/`sale`, wire-safe `fromWire`) + `ScanSession.operation`.
- `ai_api.dart`: `createScan` now requires `operation` (body `{operation, shelf_id, note}`); confirm docstring updated to the per-operation semantics.
- `ai_count_screen.dart`: wizard parametrized — **Step 0 operation chooser** (count → zone → shelf → image; receive/sale → image directly, `shelf_id` omitted), per-operation titles (`AI Receive · Step 2 of 2`, etc.), confirm-dialog copy, confirm-button label and success text; image step gains a **Take a photo** card wired to the camera screen.
- **New `camera_capture_screen.dart`**: full-screen `mobile_scanner` (already in pubspec at `^7.4.0`, no new dependency). v7 has **no manual shutter** — capture uses `MobileScannerController(returnImage: true)` + the `barcodes` stream: the first frame delivered alongside a recognized barcode pops as `CameraCaptureResult` (bytes + barcode). Permission/unsupported errors render an in-screen error state. CAMERA permission is supplied by the plugin's own Android manifest (no app-manifest edit needed).
- `inventory_models.dart`: added `MovementType.count` (`COUNT`) + label; `movements_screen.dart`: added **Counts / Sales / Purchases** filter chips (now All·Opening·Adjustments·Counts·Sales·Purchases·Write-offs, horizontally scrollable) + badge colors (COUNT info, PURCHASE success, SALE error).
- Widget tests: `ai_count_test.dart` 27 → **32** (+ operation-chooser render; receive posts `operation: receive` + `shelf_id: null` and skips zone/shelf; sale flow + SALE confirm copy + result text; receive confirm copy; `AiScanOperation.fromWire` unit). `inventory_layout_test.dart` write-offs test now scrolls the wider chip row before tapping. Full regression: `dart format` clean · `flutter analyze` → **No issues found!** · `flutter test` → **137 passed, 25 skipped (live), 0 failures**.

### Live E2E (all run, `LIVE_API=true` against `127.0.0.1:8000` + local Postgres 18.6)

- `test/live_ai_test.dart` 9 → **12 tests**: + receive → confirm → `PURCHASE` movement (`delta +1`, resulting `system+1`, stock raised); + sale → confirm → `SALE` movement (`delta −1`, stock lowered); + sale with detected > available → confirm **422 `VALIDATION_ERROR`**, no movement, stock unchanged. **12/12 passed** (full scan lifecycle, 404 surface, RBAC boundary, six PATCH scenarios, three operation scenarios).

### Unverified / deferred

- **Physical-device camera capture is UNVERIFIED** — no ADB target on this host; must be exercised with the on-device checklist before release. Barcode-triggered frame capture only (mobile_scanner 7.4.0 API constraint).
- **Real AI inference absent** (M4-B BLOCKED, unchanged): a real camera JPEG sent to `MockAIVisionPort` deterministically yields the documented fallback (visual, 0.40 confidence, unmatched) → `needs_review`. Honest, never a silent stock change; demo path remains the deterministic mock scenes.
- `flutter build apk --release` warns that `mobile_scanner` applies KGP (future Flutter "Built-in Kotlin" builds may reject it) — monitor plugin releases.
- CORS `*` placeholder, no logging redaction, no rate limiting: unchanged P2 items from A11.

### Supersessions (additive; historical entries not rewritten)

- `[M4_A5_STATUS]`/`[M4_A6_STATUS]` describe the wizard as "3-step (zone → shelf → image)". It is now **operation-first**: count is 4 steps (operation → zone → shelf → image), receive/sale are 2 (operation → image). The M4-A.6 note that "M4-B replaces `MockScanImageSource` with a camera source without touching the wizard" is superseded — the camera path (`camera_capture_screen.dart`) ships now behind the same `ScanImageSource`-adjacent acquisition flow, and the wizard was parametrized for operations.

---

## [CAMERA_AI_M4B] — External Vision API + Camera Plugin Migration, verified 2026-08-17

**DONE (as scoped).** M4-B delivers two capabilities: (1) **Real AI Vision** via a provider-agnostic external API adapter, and (2) **Manual camera capture** via the Flutter `camera` plugin replacing `mobile_scanner`.

### Backend — External Vision API (B2)

- **Provider config** (`app/config.py`): `ai_vision_provider`, `ai_vision_api_key`, `ai_vision_model`, `ai_vision_timeout` (env-driven). `.env.example` updated. API key is server-side only, never in Flutter/APK/Git.
- **`RealAIVisionPort`** (`app/ai/real_vision.py`): Provider-agnostic adapter (~320 lines). Two concrete providers: `OpenAIVisionProvider` (ChatCompletions API, base64 images) and `GoogleVisionProvider` (generateContent API, base64 images). Provider selected once at init from `AI_VISION_PROVIDER` env var.
- **Response parser** (`_parse_items`): Handles raw JSON, markdown-fenced JSON, partial/malformed entries. Extracts: name, brand, barcode, sku, category, quantity, confidence, ocr_text, description.
- **Composition root** (`app/ai/__init__.py`): Lazy import — tries `RealAIVisionPort` when provider is configured, falls back to `MockAIVisionPort` when not.
- **Product resolution** (`ai_service.py`): Extended with third priority: barcode → SKU → **name/visual matching** (new `_resolve_product_by_name`: exact ILIKE first, then word-overlap scoring across active store products, minimum score ≥2). Tenant/store isolation enforced.
- **httpx** added to main deps in `pyproject.toml` (`>=0.27,<1`).
- **Backend tests** (`tests/test_real_vision.py`): 31 tests — MIME detection (4), response parsing (10), provider configuration (4), RealAIVisionPort mocked behavior (5), composition root integration (2), name resolution integration (5). All 192 backend tests pass, ruff lint clean.

### Mobile — Camera Plugin Migration (C1-revised)

- **Dependency change**: `mobile_scanner ^7.4.0` **removed** from `pubspec.yaml`, replaced by `camera: ^0.12.0`. Reason: neither `mobile_scanner` 6.x nor 7.x provides `takePicture()` or any on-demand frame capture API — images are only delivered alongside barcode recognition via the `barcodes` stream. The `camera` plugin provides standard `takePicture()` returning `XFile` bytes.
- **`camera_capture_screen.dart`** rewritten: Uses `CameraController` + `takePicture()` for on-demand manual capture. Permission denied / unsupported errors render in-screen error state. Torch toggle via `setFlashMode`. Pops `CameraCaptureResult(imageBytes:)` with optional `barcodeValue` (null for manual capture).
- **`ai_count_screen.dart`** updated: `AiCountScreen` gains `initialOperation` parameter. When set, the wizard skips the operation chooser and jumps straight to image capture. Back button pops directly instead of stepping through wizard levels. `_capturePhoto` handles optional `barcodeValue` gracefully.
- **`inventory_overview_screen.dart`** updated: Three nav buttons — "AI Count" (existing), "AI Sale" (new, `initialOperation: sale`), "AI Receive" (new, `initialOperation: receive`). All gated by `ai.scan` permission.
- **Mobile tests**: 140 passed, 25 skipped, no regressions. Three new tests for `initialOperation` (sale skips chooser, receive skips chooser, back pops on direct entry). `flutter analyze` clean.

### What's NOT in this sprint
- No API key provided yet — `get_vision_port()` returns `MockAIVisionPort` (no key in `.env`). Live inference is mock until key is supplied.
- Physical Android device: no ADB target — camera capture UNVERIFIED.
- `PROJECT_MAP.md` tech stack updated: `mobile_scanner` → `camera`, `httpx` added.
- Prior `[CAMERA_AI_INVENTORY]` entry preserved (three scan operations + wizard).

### Supersessions
- `[CAMERA_AI_INVENTORY]` camera path note ("mobile_scanner 7.x, no manual shutter, barcode-triggered") is superseded: camera capture is now manual via `camera` plugin `takePicture()`. Operation chooser still present but also bypassable via `initialOperation`.
- `[CAMERA_AI_M4B]` "mobile_scanner removed" is superseded: `mobile_scanner 7.4.0` restored alongside `camera 0.11.0` as a dual-plugin architecture. `camera` handles manual photo capture; `mobile_scanner` handles barcode scanning exclusively. Exclusive camera ownership enforced (never both active simultaneously). Android Gradle `subprojects` block injects `androidx.concurrent:concurrent-futures` to resolve CameraX compile conflict.

---

## [MILESTONES] — verifiable goals (DoD)

| M | Goal | Verifiable DoD |
|---|---|---|
| **M0** | Bootstrap (monorepo, backend, DB, migrations, Flutter, compose) | `GET /health`=200 · Postgres 18.4 up · `alembic upgrade head` on fresh DB · migrations re-runnable on clean env · Flutter project creates+analyzes · backend structure runs · compose files authored |
| **M1** | Auth + RBAC + **Multi-Tenant** + Devices | Tenant created · login issues JWT · cashier on owner endpoint = 403 · cross-tenant request = 403/404 · device lock/revoke blocks request |
| **M2** | **Catalog + Store Layout + Suppliers + Inventory** | Tenant → Store → Zones → Shelves created · products added & tenant/store-scoped · **Product Visual Profiles (multiple ref images)** · suppliers · inventory mgmt · low/out/expiry computed · audit on every sensitive change |
| **M2.5** | **Real Dataset & Store Onboarding** | ≥1 real store: 100–300 real products, multiple ref images, shelf photos, real qty, zone/shelf mapping, ground truth recorded |
| **M3** | POS | Barcode→product→cart→checkout atomic sale deducts stock · offline sale syncs on reconnect · receipt |
| **M4** | **AI Vision (store-aware)** | Real image → store context → detection → barcode/OCR/visual matching → SKU → count → expected vs actual → variance → accuracy % · **non-blocking API** · confidence<threshold → Needs Review, never auto-stock-change · single FastAPI process |
| **M5** | Dashboard + Analytics + AI Insights | Dashboard from queries · 4 sample questions answered from real DB data (never hallucinated) |
| **M6** | Purchasing + Notifications + Email + Demo | PO Draft→Approved→Sent(email)→Received · notification center + FCM · full scope-freeze scenario passes with real data |
