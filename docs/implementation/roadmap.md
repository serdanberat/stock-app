# Implementation Roadmap

> **Status:** Draft (Phase 2A–2D locked; Phase 2E, 3 and 6 still TBD)
> **Last updated:** 2026-05-15

This roadmap turns the locked architecture into an executable plan. Stack and screen design are open questions (TODO below).

---

## Open Strategic Decisions (Resolve Before Sprint 0)

- [ ] **TODO** — Backend stack choice (Node.js/NestJS vs. Python/FastAPI vs. .NET vs. Go). Driven by team skills and ecosystem maturity for the patterns we need (RLS, JSONB, outbox).
- [ ] **TODO** — Frontend stack choice (React + Vite vs. Next.js; component library; state management).
- [ ] **TODO** — Hosting baseline (AWS / Azure / GCP / Hetzner; managed PostgreSQL vs. self-managed).
- [ ] **TODO** — Object storage choice (S3 / S3-compatible).
- [ ] **TODO** — Event bus for MVP (in-process publisher worker → Phase 6 stack decision will determine).
- [ ] **TODO** — e-Belge provider (deferred to v1.1; pre-select to keep schema honest).
- [ ] **TODO** — Pricing tier amounts (pending competitor research).
- [ ] **TODO** — Beta tenant recruitment (≥3 stores for early access).

---

## Phase Plan (High-Level)

| Phase | Deliverable | Status |
|---|---|---|
| 1 | Product decisions | ✅ Done |
| 2A | Bounded contexts | ✅ Done |
| 2B | Aggregates, ownership, invariants | ✅ Done |
| 2C | Lifecycles & state machines | ✅ Done |
| 2D | Domain events, consumers, sagas | ✅ Done |
| 2E | Database schema (CREATE TABLE) | Not started |
| 3 | Screen wireframes (text-mockups) | Not started |
| 4 | Backend architecture (module layout, layering) | Not started |
| 5 | API structure (endpoint catalogue) | Not started |
| 6 | Tech stack selection (backend + frontend) | Not started |
| 7 | Coding (sprints below) | Not started |

**Phase 2D deliverables** (see `/docs/architecture/` and `/docs/adr/`):

- `domain-events.md` — full event catalog (~60 events), envelope, schema versioning, ordering, PII rules
- `event-consumers.md` — consumer catalog, idempotency contract, replay vs. rebuild, DLQ operations
- `saga-processes.md` — multi-step flows (Exchange, Transfer, DayEndClose, TenantLifecycle, SaleDocumentGeneration, OutboxRecovery)
- ADR 008 — Domain events and outbox implementation specifics
- ADR 009 — Sagas, eventual consistency, replay/rebuild, PII reversibility

---

## Implementation Sprints (MVP)

Sprint length: 2 weeks. Estimates are placeholders pending team-size confirmation.

### Sprint 0 — Foundations (2 weeks)

Goal: a runnable empty system with auth, multi-tenancy and one trivial CRUD path.

- Repo scaffolding (mono-repo: `apps/api`, `apps/web`, `packages/domain`, `packages/db`).
- CI / CD pipeline.
- Postgres + migrations framework chosen (e.g. Liquibase / Flyway / Sqitch / Atlas).
- Migration: `tenants`, `users`, `roles`, `user_roles`, `stores`, `user_store_access`.
- RLS policies on the above tables; CI lint rule that fails if a new table is missing RLS.
- Authentication (email + password; password hashing; session/token TBD by stack).
- `app.tenant_id` middleware.
- **Outbox table with Phase 2D shape**: full envelope columns, `status ∈ {PENDING, PUBLISHED, FAILED, DEAD_LETTER}`, `dead_letter_at`, `dead_letter_reason`, `partition_key`, `outbox_sequence`, `global_sequence`.
- **`processed_events` table** for consumer idempotency (composite PK `(consumer_name, event_id)`).
- **`security_audit_log` table** (separate stream from the outbox, per ADR 008).
- Placeholder publisher worker that reads outbox `FOR UPDATE SKIP LOCKED` and applies retry/backoff; no real consumers yet.
- Basic health-check, metrics, structured logging.
- One vertical slice: create a Brand (Catalog), list Brands, with the full request → RLS → DB path proven, including an emitted outbox event with the standard envelope.

### Sprint 1 — Catalog Core (2 weeks)

- Categories (hierarchy, max 5 levels, cyclic-ref guard).
- Brands, Seasons.
- Attribute system (colors, sizes, materials).
- Products + ProductVariants + VariantBarcodes (with scope: INTERNAL / SUPPLIER / GS1_EAN).
- Variant matrix editor.
- Smart code template engine.
- Price cipher utility.
- ProductImages / VariantImages (object storage adapter).
- Audit consumer for catalog events.

### Sprint 2 — Inventory Foundation (2 weeks)

- `stock_movements` (append-only, partitioned-ready).
- Append-only enforcement: REVOKE + guard trigger.
- `stock_balances` projection maintained transactionally.
- `InventoryService.recordMovement()` API (the single writer).
- WAC engine integrated into IN/OUT movements.
- Movement type taxonomy fully enumerated.
- Idempotency for adjustments.
- Reconciliation job (nightly).
- Rebuild command.

### Sprint 3 — Purchasing (2 weeks)

- Parties (unified customer/supplier/employee).
- PartyContacts, PartyDocuments.
- FX context: `currencies`, `fx_rate_sources`, `fx_rates`, `fx_snapshots`.
- TCMB provider; MANUAL provider; HAREM provider skeleton (defer real integration if blocked).
- Tenant FX preference setting.
- PurchaseInvoice draft → post (atomic transaction: items + stock IN + supplier debt + FX snapshot).
- PurchaseReturn.

### Sprint 4 — Financial Core (2 weeks)

- `AccountProfile` aggregate.
- `account_movements` (append-only journal).
- `account_balances` projection.
- Payment aggregate (RECEIVED / MADE).
- PaymentAllocation (auto-FIFO + manual override).
- Payment reversal (FULL / PARTIAL).
- Credit limit enforcement.
- Aging projection (nightly).

### Sprint 5 — POS Sales Hot Path (2.5 weeks)

- Sale aggregate with state machine (DRAFT → AWAITING_PAYMENT → COMPLETED).
- PaymentAttempts audit trail.
- Idempotency key handling.
- Atomic completion transaction (Sale + items + stock OUT + cash + account + payments + document stub + outbox).
- Cost snapshot on sale items.
- CashRegister + RegisterSession with OPEN/CLOSING/CLOSED state machine.
- Z report number sequence (gap-free allocation).
- CashMovements.
- Abandoned-cart cleanup; idle timeouts; terminal_pending handling.

### Sprint 6 — Returns and Exchange (2 weeks)

- Return aggregate (DRAFT → COMPLETED, with AWAITING_APPROVAL for high-value/BLIND).
- RECEIPTED and BLIND modes.
- Tenant-level blind-return guardrails.
- Cost snapshot rules (RECEIPTED from original; BLIND from current WAC).
- Refund processing (cash / card reversal / customer balance / debt reduction).
- Exchange flow (Return + Sale with `exchange_group_id`, two transactions).

### Sprint 7 — Inter-Store Operations & Counts (2 weeks)

- Transfer aggregate with DRAFT → DISPATCHED → RECEIVED.
- Virtual `IN_TRANSIT` store auto-creation per tenant.
- Loss reason codes (`LOST_IN_TRANSIT`, etc.).
- CountSession with snapshot + correct variance formula (REPEATABLE READ isolation).
- StockAdjustment.
- Low-stock alerts.

### Sprint 8 — Pricing, Documents, Reporting Scaffolding (2 weeks)

- PriceList + VariantPrice (append-only with EXCLUDE constraint).
- PricingService.getEffectivePrice() with caching.
- Document generation workers (PDF for receipts, invoices, Z reports).
- Object storage integration.
- Receipt printer worker (with retry queue).
- First reporting projections: daily sales summary, low stock, dead stock.
- Materialised view refresh strategy.

### Sprint 9 — UX Polish, Operational Tools (2 weeks)

- Admin console: tenant management, feature flags.
- Manager override flows (credit limit, blind return, register reopen — feature-flag-gated).
- Backup / data export.
- Migration import tooling (Excel → catalog/parties).
- Receipt and invoice templates.
- Hardware setup wizards.

### Sprint 10 — Hardening and Beta (2.5 weeks)

- Load testing (sale-completion throughput per tenant).
- Chaos testing (network partition during sale completion; verify recovery).
- RLS test suite (cross-tenant leakage attempts).
- Idempotency test suite (POS retry storms).
- Reconciliation test suite (ledger ↔ projection drift).
- Onboarding wizard for first beta tenants.
- Documentation for users (admin guide, cashier quickstart).

### Sprint 11 — Beta Stabilisation (2 weeks)

- Real-tenant feedback cycle.
- Bug fixes and UX iteration.
- e-Belge provider deferred decision finalised; integration stub.
- Performance tuning based on real workloads.

**End of MVP** — typically 12 calendar weeks of engineering work (assuming one senior backend, one senior frontend, plus support).

---

## Post-MVP Tracks

### v1.1 (3–6 months after launch)

- Campaigns / promotions / BOGO / coupons.
- Loyalty points and gift cards.
- Wholesale and VIP price lists.
- Commission engine.
- ABC analysis, turnover, dead-stock analytics.
- Reorder suggestions.
- e-Arşiv / e-Fatura full integration.
- Bank account reconciliation, POS/card reconciliation.
- Async variant generation (background job for >200-variant products).
- FxRate table partitioning.
- Offline POS (the hardest single feature; plan a dedicated sub-roadmap).

### v2 (12 months+)

- Multi-currency cash registers.
- Jewellery module (gramaj / ayar / live gold rates / piece-level serials / workmanship).
- Cafe / restaurant module (recipes, tables, KDS, hesap bölme).
- Mobile companion app (owner dashboard + cashier mobile POS).
- e-commerce integrations (Trendyol, Hepsiburada, Shopify).
- Accounting software exports (Logo, Mikro).
- Multi-region deployment, data residency options.
- Custom report builder.
- Zone/bin-scoped parallel counts.

---

## Quality Gates

Each sprint must pass these gates before merging:

| Gate | Check |
|---|---|
| RLS coverage | Every new domain table has RLS policy + cross-tenant leak test |
| Append-only enforcement | New ledger-like tables enforce immutability (test that UPDATE/DELETE raise) |
| Idempotency (write side) | Every state-changing endpoint that affects money or stock has an idempotency test |
| Idempotency (consumer side) | Every new outbox consumer writes a `processed_events` row in the same transaction as its projection update and is tested under duplicate-delivery |
| Atomic transactions | Hot-path operations have a "kill mid-transaction" test that verifies clean state |
| Outbox envelope | Every produced event conforms to the envelope in `domain-events.md`; CI lints producers against the schema registry |
| Outbox event coverage | Every cross-context state change has an outbox event with a consumer (or a documented "no consumer yet" stub) |
| Stream separation | Security events (login, MFA, password) go to `security_audit_log`, not to `outbox_events` |
| Replay / rebuild | Every projection has a `rebuild_*` command that reconstructs it from append-only sources; the command is exercised in a test |
| DLQ handling | Any new failure mode that may permanently fail an event is mapped to a `dead_letter_reason`; DLQ size and age have monitoring |
| Audit | Critical operations (`*AdministrativelyReversed`, `RegisterSessionReopened`, `BlindReturnApproved`, `CreditLimitExceeded`) produce dedicated audit events |
| Migration linting | CI rejects migrations without tenant_id + RLS for domain tables |

---

## Risks and Mitigations

| Risk | Mitigation |
|---|---|
| RLS misconfiguration leaks tenant data | CI lint + cross-tenant test suite + code review checklist |
| Outbox publisher falls behind | Monitoring on publisher lag; alert on PENDING age > 60s; alert on FAILED count > 100 |
| Dead-letter queue accumulation | Monitoring on DLQ size (> 100 warning, > 1000 critical) and age (> 24h review); `OutboxEventDeadLettered` events wired to notification consumer |
| Ledger projection drift | Nightly reconciliation emits `ReconciliationDriftDetected`; **no auto-rebuild** — human triages, then runs `rebuild_*` command |
| Saga partial outcomes confuse operators | Process-instance state surfaced in admin dashboards; `TransferDelayed`, `requires_manual_reconciliation` flags drive operator queues |
| Consumer non-idempotency causes duplicate side effects | Mandatory `processed_events` write in same transaction as projection update; tested under duplicate-delivery in CI |
| Event-schema drift breaks consumers | Schema validation at both producer and consumer; mismatch routes to DLQ with `SCHEMA_MISMATCH` reason; schema registry per event type |
| POS feels slow due to lock contention | Canonical lock order + targeted indexes; load testing in Sprint 10 |
| e-Belge integration delays | Schema is decoupled from provider; submission is async; manual fallback documented |
| Scope creep (sectoral expansion in MVP) | Strategy locked: clothing/boutique only for MVP; metadata JSONB keeps future doors open |
| PII anonymisation regret (irreversible by default) | Documented in ADR 009; reversible pseudonymisation is opt-in with contractual gating and HSM-backed key vault |

---

## What Is Explicitly Out of Scope for MVP

- Offline POS (v1.1).
- Mobile applications (v2).
- e-Commerce marketplace integrations (v2).
- Multi-currency cash registers (v2).
- Jewellery / cafe modules (v2).
- Custom report builder (v2).
- Multi-region deployment (v2 if ever).
- Real-time inventory sync across tenants / global marketplace catalogue (v2 if ever).

Carrying these explicitly prevents architecture creep during MVP execution.
