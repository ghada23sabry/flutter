# AGENTS.md

## What this is
VisionStock AI — multi-tenant retail SaaS (POS + AI inventory vision). Monorepo, currently M0 bootstrap: FastAPI skeleton + empty Flutter/AI/dataset scaffolding. No auth layer, no tests, no CI yet.

## Start here
- `PROJECT_MAP.md` is the **design of record and memory ledger**. Read it before changing architecture. Updating it when the stack, flow, or architecture changes is a stated maintainer obligation — do it.
- Design principle (Protocol 3): single FastAPI process, feature-domain grouping, shared `core` only for logic truly repeated. No microservices, no Redis/Celery in MVP. Preserve unless there's evidence.

## Layout
- `services/api` — FastAPI backend (the only code so far). Run Python commands from this directory.
- `apps/mobile` — Flutter client (empty; Android-first, APK build deferred).
- `ai/` — dataset/models/training (empty; `.pt`/`.onnx` artifacts are gitignored — kept external).
- `infra/docker-compose.yml` — api + postgres 18.4; compose auto-runs `alembic upgrade head` before starting uvicorn.

## Commands (cwd = `services/api`)
- Install: `pip install -e ".[dev]"` (dev deps: pytest, pytest-asyncio, httpx, ruff)
- Run dev server: `uvicorn app.main:app --reload` — requires `DATABASE_URL`; copy `.env.example` to `.env`
- Migrations: `alembic upgrade head` / `alembic revision --autogenerate -m "..."` — **requires DATABASE_URL in env or `.env`**; `alembic.ini` URL is intentionally empty (`migrations/env.py` pulls it from `app.config.get_settings()`)
- Tests: `pytest` — `asyncio_mode = "auto"` is configured, no `@pytest.mark.asyncio` needed
- Lint: `ruff check` (line-length 120)

## Multi-tenant security — hard rules
Mandatory gate on every endpoint: JWT → account active → device active → tenant (from token, **never from client params**) → store (from path, must belong to tenant) → role → permission → row-scoped query.
- Cross-tenant access → 404 (preferred over 403; never leak existence).
- No `core/security` exists yet — build it before adding any feature router. Do not ship public endpoints.
- Tenant/store scoping must be enforced structurally (shared dependency/repository), not duplicated per feature.

## Backend conventions
- Versions are pinned deliberately — respect `PROJECT_MAP.md` TECH_STACK. Explicitly rejected: SQLAlchemy 2.1.x (beta), PostgreSQL 19 (beta), ultralytics 8.4.35/8.4.44 (yanked). Python prod image is `3.14-slim`.
- Async throughout: SQLAlchemy 2.0 async + asyncpg, async Alembic, session via `app/core/db.get_db`.
- Models grouped by domain in `app/models/` (NOT one file per table); Pydantic v2 schemas in `app/schemas/`.
- `passlib[bcrypt]` is in deps but unmaintained — use `bcrypt` directly for new hashing code.
- Logging (`app/core/logging`): async `QueueHandler`/`QueueListener`, JSON lines, configured in app lifespan. Never log tokens/passwords/PII; sensitive mutations go to DB `audit_logs`, not logs.
- Migration revision IDs are semantic strings ("0001"), not hashes — follow that convention.

## Gotchas
- Docker compose has not been live-verified on this host (no Admin/WSL2) — files authored, not proven. Local Postgres is portable binaries (user-scope, no service).
- **Local Postgres backend crash on connect** (`could not reserve shared memory region ... error code 487`): PG18 defaults to `shared_memory_type = mmap`, which fails under Windows ASLR/AV. Fix already applied in local `C:\Users\PC\pgsql\data\postgresql.conf`: `shared_memory_type = windows`. Keep it if you re-init the data dir.
- `app/main.py` sets `CORSMiddleware(allow_origins=["*"])` — known placeholder, tighten when auth lands.
- `infra/`, `migrations/`, `ai/` were empty scaffolding until recently — re-check actual state before assuming the `PROJECT_MAP.md` plan matches the tree.

---

# BIG BECKEL — UNIVERSAL SOFTWARE ENGINEERING STANDARD

## Precedence

Apply this methodology to every future task in this repository. The **project-specific verified rules above remain authoritative**. When a universal rule conflicts with a verified project-specific constraint, do not silently choose: analyze the conflict, preserve the documented project decision when appropriate, and explain the conflict before making a destructive architectural change.

The goal is not merely to generate working code. The goal is to produce **correct, secure, clean, maintainable, testable, scalable, production-grade** software.

## Engineering lifecycle

For every non-trivial task follow:

```
INSPECT → UNDERSTAND → PLAN → ARCHITECT → IMPLEMENT → TEST → REVIEW → SECURITY AUDIT → REFACTOR → VERIFY → DELIVER
```

Do not skip a relevant phase.

## 1. INSPECT FIRST

Before modifying an existing system, inspect: repository structure, relevant source files, configuration, dependencies, database schema, API contracts, existing tests, existing architecture, project documentation, `AGENTS.md`, and `PROJECT_MAP.md` when applicable.

- Never invent existing project behavior.
- Never assume a file, API, dependency, command, configuration, or architectural component exists without verification.

## 2. UNDERSTAND BEFORE CODING

Determine: what the user actually needs; what already exists; what must change; what must remain unchanged; affected components; dependencies; side effects; security boundaries; compatibility constraints; performance implications.

Do not immediately start writing code.

## 3. PLAN

For significant changes, create a concise implementation plan identifying: files to modify; files to create; architecture impact; database impact; API impact; dependencies; migrations; tests; security implications; rollback considerations.

Prefer the smallest safe change that completely solves the problem.

## 4. ARCHITECTURE

Follow SOLID, DRY, KISS, YAGNI, Separation of Concerns, High Cohesion, Low Coupling, Dependency Inversion, Explicit Contracts, and Clear Module Boundaries.

- Do not introduce design patterns simply because they exist.
- Do not over-engineer. Do not under-engineer.
- Use the simplest architecture that remains robust for the actual requirements.
- Preserve the existing architecture unless there is a verified reason to change it.

## 5. IMPLEMENTATION

Write production-quality code. Code should be readable, explicit, modular, predictable, maintainable, and testable.

Avoid: giant functions; god classes; duplicated business logic; unnecessary abstraction; hidden side effects; magic values; unnecessary globals; dead code; unused dependencies; premature optimization; unrelated refactoring.

Reuse existing project functionality whenever appropriate. Do not create duplicate implementations of functionality that already exists.

## 6. DATABASE

For database changes: preserve data integrity; use transactions where required; use parameterized queries; validate migrations; preserve backward compatibility where required; consider concurrency, indexes, constraints, and rollback.

Never silently alter production data behavior. Follow the repository's existing database conventions and verified commands.

## 7. API

Every protected API must enforce appropriate authentication, authorization, input validation, ownership/tenant isolation, error handling, and rate limiting where appropriate.

Never trust client-controlled: user IDs, tenant IDs, roles, permissions, prices, ownership, or status values. Authorization must be enforced server-side.

## 8. SECURITY-FIRST DEVELOPMENT

Treat all external input as untrusted. Before completion actively check for: SQL injection; NoSQL injection; command injection; XSS; CSRF; SSRF; IDOR; broken access control; privilege escalation; authentication bypass; authorization bypass; path traversal; unsafe file upload; unsafe deserialization; race conditions; TOCTOU; sensitive data exposure; secret leakage; insecure logging; insecure sessions; API abuse; dependency vulnerabilities.

Never expose: passwords, API keys, tokens, secrets, private credentials, internal stack traces, or sensitive database information.

Security must be part of implementation, not merely a final checklist.

## 9. MULTI-TENANT SECURITY

Because this repository uses multi-tenant architecture:

- NEVER trust tenant identity supplied by the client.
- Tenant identity must come from the authenticated security context.
- Every tenant-owned database operation must enforce tenant isolation.
- Every store-scoped operation must verify that the store belongs to the authenticated tenant.
- Authorization must happen before sensitive data access.
- Cross-tenant access must fail safely.
- Never rely solely on developer discipline for tenant isolation when a structural enforcement mechanism is available.

## 10. TESTING

Do not consider code complete merely because it runs. Test: happy paths; edge cases; invalid input; error paths; authentication; authorization; tenant isolation; database behavior; concurrency where relevant; regression scenarios; security-sensitive paths.

Use the project's actual test tooling. Run relevant tests after changes. Never fabricate test results. If something could not be executed, explicitly report it.

## 11. ADVERSARIAL CODE REVIEW

After implementation, assume the implementation contains a serious bug. Try to break it. Review as Principal Software Architect, Senior Software Engineer, Security Engineer, QA Engineer, Performance Engineer, and Future Maintainer.

Ask: What can fail? What can be abused? What happens with malformed input? What happens concurrently? What happens when dependencies fail? Can data become inconsistent? Can authorization be bypassed? Can tenant isolation fail? Is the abstraction justified? Is anything duplicated? Is there a simpler robust implementation? Will this remain maintainable?

For every discovered issue: FIND → CLASSIFY → FIX → TEST → RE-REVIEW.

## 12. ROOT-CAUSE DEBUGGING

When something fails, do not immediately patch the visible symptom. Use:

```
OBSERVE → REPRODUCE → TRACE → IDENTIFY ROOT CAUSE → FIX ROOT CAUSE → ADD REGRESSION TEST → VERIFY
```

Never repeatedly patch symptoms without understanding the underlying cause.

## 13. CHANGE DISCIPLINE

- Make the smallest safe change.
- Do not modify unrelated files.
- Do not rewrite working architecture unnecessarily.
- Do not introduce a new dependency when existing project capabilities can solve the problem adequately.
- Do not change verified version pins or architectural decisions without evidence and explicit justification.

## 14. VERIFICATION

Before declaring completion, verify what the environment actually allows: syntax; imports; type checking; linting; build; tests; migrations; API contracts; integration points; security-sensitive paths.

Clearly distinguish **VERIFIED / NOT VERIFIED / ASSUMED**. Never fabricate evidence.

## 15. PROJECT MEMORY

When an architectural, dependency, security, migration, or operational decision materially changes the project, update the project's designated memory ledger according to the existing repository convention. For this repository, respect the existing `PROJECT_MAP.md` memory-ledger obligation.

Keep project documentation synchronized with actual implementation. Never document a feature as implemented if it has not actually been implemented and verified.

## 16. COMPLETION STANDARD

A task is COMPLETE only when: requested behavior is implemented; architecture remains coherent; security has been reviewed; relevant tests exist; relevant tests have been executed where possible; integration points are verified; no known critical issue remains.

If verification is incomplete, do not claim full completion — state exactly what remains unverified. Never claim "perfect", "100% secure", or "zero vulnerabilities". Use precise engineering language instead.

## Final response standard

When completing a task, report concisely but precisely:

1. WHAT CHANGED
2. WHY
3. FILES AFFECTED
4. ARCHITECTURE IMPACT
5. TESTS EXECUTED
6. SECURITY REVIEW
7. KNOWN LIMITATIONS
8. UNVERIFIED ITEMS
