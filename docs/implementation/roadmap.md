# Implementation Roadmap

> **Status:** Phase 1, 2A–2E, 6, 3.A and 3.B locked. Phase 3.C–3.E, 4, 5 next.
> **Last updated:** 2026-05-16

This roadmap turns the locked architecture into an executable plan.

---

## Open Strategic Decisions

| Decision | Status |
|---|---|
| Backend stack | ✅ Locked Phase 6.A (Java 21, Spring Boot 4.0.x, JPA + JOOQ) |
| Frontend stack | ✅ Locked Phase 6.E (React 19 + Vite + TypeScript + Mantine v8 + TanStack) |
| Hosting baseline | ✅ Locked Phase 6.I (€0 MVP: Fly.io + Neon + Cloudflare Pages) |
| Object storage | ✅ Locked Phase 6.F (DocumentStorage abstract; LocalFS MVP, R2/S3 v1.1+) |
| Event bus for MVP | ✅ Locked Phase 6.F (in-process outbox dispatcher) |
| e-Belge provider | TODO v1.1+ |
| Pricing tier amounts | TODO (competitor research) |
| Beta tenant recruitment | TODO (≥3 stores) |

---

## Phase Plan

| Phase | Deliverable | Status |
|---|---|---|
| 1 | Product decisions | ✅ Locked |
| 2A | Bounded contexts | ✅ Locked |
| 2B | Aggregates, ownership, invariants | ✅ Locked |
| 2C | Lifecycles & state machines | ✅ Locked |
| 2D | Domain events, consumers, sagas | ✅ Locked |
| 2E | Database schema (68 tables + 5 mviews) | ✅ Locked |
| **6** | **Tech stack selection (9 sub-phases)** | **✅ Locked** |
| 3 | Screen wireframes (text-mockups, 5 sub-phases) | In progress (3.A + 3.B locked) |
| 4 | Backend architecture detail (module-by-module) | After Phase 3 |
| 5 | API endpoint catalogue + OpenAPI | After Phase 4 |
| 7 | Implementation (12 sprints) | After Phase 5 |

### Phase 3 sub-phases

| Sub-phase | Topic | Status |
|---|---|---|
| **3.A** | **POS Flow (7 screens)** | **✅ Locked** |
| **3.B** | **Catalog Management (5 + 1 secondary screens: product list, create/edit, variant matrix, pricing, attributes, missing items)** | **✅ Locked** |
| 3.C | Inventory Operations (stock list, transfer, count, adjustment) | Next |
| 3.D | Financial Flows (purchase invoice, return/exchange, payment collection, account detail) | After 3.C |
| 3.E | Operational/Admin (cash close + Z report, user/role admin, tenant flags, basic reports) | After 3.D |

### Phase 3.B deliverables (locked, this milestone)

| Screen | Doc |
|---|---|
| 3.B.1 | Product List | `screens/catalog/3b1-product-list.md` |
| 3.B.2 | Product Create/Edit | `screens/catalog/3b2-product-edit.md` |
| 3.B.3 | Variant Matrix Builder | `screens/catalog/3b3-variant-matrix.md` |
| 3.B.4 | Pricing Screen | `screens/catalog/3b4-pricing.md` |
| 3.B.5 | Attribute Configuration | `screens/catalog/3b5-attributes.md` |
| 3.B.6 | Missing Item Requests (secondary tab) | `screens/catalog/3b6-missing-items.md` |
| Index | Locked decisions + schema + API endpoints | `screens/catalog/README.md` |
| ADR-018 | Pricing Resolution Strategy | `adr/018-pricing-resolution-strategy.md` |
| ADR-019 | Display Name Composition Strategy | `adr/019-display-name-composition.md` |
| Migration | Catalog extensions consolidated | `migrations/019_catalog_extensions.sql` |

### Phase 3.A deliverables (locked, this milestone)

| Screen | Doc |
|---|---|
| 3.A.1 | POS Main Sale | `screens/pos/3a1-main-sale.md` |
| 3.A.2 | Product Search Modal (F1) | `screens/pos/3a2-product-search.md` |
| 3.A.3 | Customer Select Modal (F2) + Quick Create | `screens/pos/3a3-customer-select.md` |
| 3.A.4 | Discount Modal (F3) | `screens/pos/3a4-discount.md` |
| 3.A.5 | Payment Screen | `screens/pos/3a5-payment.md` |
| 3.A.6 | Terminal Pending / Recovery | `screens/pos/3a6-terminal-pending.md` |
| 3.A.7 | Completion / Receipt | `screens/pos/3a7-completion.md` |
| Index | Locked decisions catalog + schema additions + API endpoints | `screens/pos/README.md` |
| Migration | POS extensions consolidated | `migrations/018_pos_extensions.sql` |

### Phase 6 deliverables (locked, this milestone)

| Sub-phase | Topic | Doc |
|---|---|---|
| 6.A | Backend core (Java 21, Spring Boot 4, JPA+JOOQ, Maven, Flyway) | `tech-stack/6a-backend-core.md` |
| 6.B | Persistence (TenantAwareTransactionManager, RLS integration, JSONB typing) | `tech-stack/6b-persistence.md` |
| 6.C | Modular monolith (10 modules, service families, ArchUnit) | `tech-stack/6c-modular-monolith.md` |
| 6.D | Auth & security (JWT, HMAC pepper, Caffeine, Bucket4j, MFA-ready) | `tech-stack/6d-auth-security.md` |
| 6.E | Frontend (Mantine v8, TanStack, ky, Dinero v2, react-hook-form) | `tech-stack/6e-frontend.md` |
| 6.F | Jobs & documents (ShedLock, Gotenberg, TX1/External/TX2 pattern) | `tech-stack/6f-jobs-documents.md` |
| 6.G | Observability (Micrometer, Sentry, OTel-ready, 5 dashboards, 9 alerts) | `tech-stack/6g-observability.md` |
| 6.H | Test stack (Testcontainers, ArchUnit, RLS parametrized, Playwright smoke) | `tech-stack/6h-test-stack.md` |
| 6.I | DevOps & deploy (€0 MVP: Fly.io + Neon + Cloudflare + GitHub Actions) | `tech-stack/6i-devops-deploy.md` |

New ADRs added in Phase 6:

- ADR-010 JSONB Typed Records
- ADR-011 Tenant Context via Spring Security
- ADR-012 Aggregate Ownership Rules
- ADR-013 Tenant Resolution Strategy
- ADR-014 Stateless JWT with DB-backed Refresh Tokens
- ADR-015 Token Hashing with HMAC-SHA256 Pepper
- ADR-016 Permission Caching Strategy
- ADR-017 External I/O Outside Database Transactions

New architecture documentation:

- `architecture/tenant-context-flow.md`
- `architecture/jsonb-typing-rules.md`
- `architecture/isolation-levels.md`
- `architecture/worker-patterns.md` (TX1 / External / TX2)
- `architecture/event-consumer-categories.md` (internal vs external)

Schema additions:

- `migrations/016_auth_extensions.sql` — user_sessions, password_reset_tokens, users.mfa_*
- `migrations/017_jobs_extensions.sql` — shedlock

---

## Implementation Sprints (MVP)

Sprint length: 2 weeks. Estimates are placeholders pending team-size confirmation.

### Sprint 0 — Foundations (2 weeks)

Goal: a runnable empty system with auth, multi-tenancy and one trivial CRUD path.

- Repo scaffolding: single Maven module with package-per-feature; frontend in `frontend/` subdir.
- `Dockerfile` (multi-stage, layered jars), `docker-compose.yml` (postgres, gotenberg, mailhog).
- CI/CD: GitHub Actions (`ci.yml` — arch+unit, integration, frontend, e2e; `release.yml` — tag → GHCR; `deploy.yml` — workflow_dispatch → Fly.io).
- Flyway migrations through 017 applied; CI gate fails if a new tenant table lacks RLS.
- ArchUnit baseline rules (20+) + Spring Modulith verify in CI.
- Spring Security setup: JwtAuthenticationFilter, TenantAwareTransactionManager, SecurityTenantProvider.
- Authentication endpoints: `/auth/login`, `/auth/refresh`, `/auth/logout`, `/auth/sessions`.
- TokenHasher (HMAC-SHA256 with pepper), BCrypt cost=12.
- MDC context filter (trace_id, tenant_id, user_id, store_id).
- Outbox table from Phase 2E; OutboxPublisher (@Transactional MANDATORY); OutboxDispatcher (claim-process-finalize); EventConsumer interface with `isInternal()` flag.
- `processed_events` and `security_audit_log` tables seeded with one no-op consumer.
- Basic health (`/actuator/health` liveness, readiness, custom OutboxLag + GotenbergHealth).
- Sentry SDK initialized (no-op DSN); Logback structured JSON; Micrometer Prometheus.
- Frontend skeleton: Vite + React + TanStack Router + Mantine + ky + Zustand + i18n (Turkish).
- 3 Playwright smoke tests scaffolded (login, POS open, complete flow assertions).
- One vertical slice: create Brand (Catalog) end-to-end with RLS proven + outbox event emitted.

### Sprint 1 — Catalog Core (2 weeks)

- Categories (hierarchy, max 5 levels, cyclic-ref guard).
- Brands, Seasons.
- Attribute system (colors, sizes, materials, etc.).
- Products + ProductVariants + ProductVariantBarcodes (scope: INTERNAL / SUPPLIER / GS1_EAN).
- Variant matrix editor (frontend).
- Smart code template engine (`PROD-{seq:6}-{category_code}`).
- Price cipher utility.
- ProductImages / VariantImages (DocumentStorage adapter).
- Audit consumer for catalog events.

### Sprint 2 — Inventory Foundation (2 weeks)

- `stock_movements` (append-only, partition-ready).
- Append-only enforcement: REVOKE UPDATE/DELETE + guard trigger.
- `stock_balances` projection maintained transactionally.
- `StockMovementService.record()` — the single writer.
- WAC engine integrated into IN/OUT movements.
- Movement type taxonomy fully enumerated.
- Idempotency for adjustments.
- Reconciliation job (nightly via ShedLock).
- Rebuild command (`stock_balances` recomputed from `stock_movements`).

### Sprint 3 — Purchasing (2 weeks)

- Parties unified (customer/supplier/employee).
- PartyContacts, PartyDocuments.
- FX context: `currencies`, `fx_rate_sources`, `fx_rates`, `fx_snapshots`.
- TCMB provider (real implementation); MANUAL provider; HAREM provider skeleton.
- Tenant FX preference setting.
- PurchaseInvoice draft → post (atomic: items + stock IN + supplier debt + FX snapshot).
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
- Service family: SaleLifecycleService, SalePricingService, SalePaymentService, SaleCompletionOrchestrator, SaleVoidService.
- PaymentAttempts audit trail.
- Idempotency key handling via `X-Idempotency-Key`.
- Atomic completion transaction (Sale + items + stock OUT + cash + account + payments + document stub + outbox).
- Cost snapshot on sale items.
- CashRegister + RegisterSession (OPEN/CLOSING/CLOSED).
- Z report number sequence (gap-free, SERIALIZABLE allocator).
- CashMovements.
- Abandoned-cart cleanup, idle timeouts, terminal_pending handling.
- Frontend POS screen: useBarcodeScanner, useHotkeys F1-F12, Dinero math, optimistic UI rules.

### Sprint 6 — Returns and Exchange (2 weeks)

- Return aggregate (DRAFT → COMPLETED, with AWAITING_APPROVAL for high-value/BLIND).
- RECEIPTED and BLIND modes.
- Tenant-level blind-return guardrails (FeatureFlags).
- Cost snapshot rules (RECEIPTED from original; BLIND from current WAC).
- Refund processing (cash / card reversal / customer balance / debt reduction).
- Exchange flow (Return + Sale with `exchange_group_id`, two transactions).

### Sprint 7 — Inter-Store Operations & Counts (2 weeks)

- Transfer aggregate with DRAFT → DISPATCHED → RECEIVED.
- Virtual `IN_TRANSIT` store auto-creation per tenant.
- Loss reason codes (`LOST_IN_TRANSIT`, etc.).
- CountSession with snapshot + variance formula (REPEATABLE READ isolation).
- StockAdjustment.
- Low-stock alerts.

### Sprint 8 — Pricing, Documents, Reporting Scaffolding (2 weeks)

- PriceList + VariantPrice (append-only with EXCLUDE constraint).
- PricingService.getEffectivePrice() with caching.
- Document workers (SaleDocumentWorker, ReturnDocumentWorker, etc.) using TX1/External/TX2 pattern.
- Thymeleaf document templates (sale-receipt, sale-invoice, return-receipt, z-report).
- Gotenberg integration (sidecar container).
- DocumentStorage LocalFS implementation.
- First reporting projections: daily_sales_summary, top_selling_variants, stock_position_summary.
- Materialized view refresh strategy (CONCURRENTLY).

### Sprint 9 — UX Polish, Operational Tools (2 weeks)

- Admin console: tenant management, feature flags.
- Manager override flows (credit limit, blind return, register reopen — feature-flag-gated).
- Backup runbook executed (GitHub Actions workflow → R2).
- Migration import tooling (Excel → catalog/parties).
- Receipt and invoice templates polished.
- Hardware setup wizards.

### Sprint 10 — Hardening and Beta (2.5 weeks)

- Load testing (sale-completion throughput per tenant) — manual benchmarks; k6 deferred to v1.1+.
- Chaos testing (network partition during sale completion; verify recovery).
- RLS test suite (cross-tenant leakage parametrized across all 45+ tables).
- Idempotency test suite (POS retry storms).
- Reconciliation test suite (ledger ↔ projection drift).
- Onboarding wizard for first beta tenants.
- Documentation for users (admin guide, cashier quickstart).
- Restore drill executed once (pg_dump backup → fresh Neon branch → verify).

### Sprint 11 — Beta Stabilisation (2 weeks)

- Real-tenant feedback cycle.
- Bug fixes and UX iteration.
- e-Belge provider decision finalized; integration stub.
- Performance tuning based on real workloads.
- First paying customer migration trigger evaluation (Hetzner CX22 + Neon Pro).

**End of MVP** — typically 12 calendar weeks of engineering work.

---

## v1.0.x / v1.1+ Triggered Upgrades

### Infrastructure (cost-driven, see Phase 6.I)

| Trigger | Action | Monthly cost |
|---|---|---|
| First paying customer | Migrate backend → Hetzner CX22; DB → Neon Pro | ~€25 |
| 3 paying customers | Upgrade to Hetzner CCX13; add Sentry self-host | ~€40 |
| 10 paying customers | Hetzner CCX23 + Sentry Pro + Prometheus/Grafana/Loki stack | ~€100 |
| 25 paying customers | Multi-instance backend + staging environment | ~€200 |
| Multi-region need | Cloudflare hybrid arch evaluation | (v2) |

### Operational

| Trigger | Item |
|---|---|
| Multi-instance enabled | Per-tenant ShedLock partitioning |
| Multi-instance enabled | Permission cache distributed invalidation (LISTEN/NOTIFY) |
| Multi-instance enabled | Pre-deploy Flyway migration step (decoupled from app startup) |
| Multi-instance enabled | Blue-green deployment via Fly.io / Caddy |
| Java 25 stable + virtual threads validated | Migrate from Java 21 to Java 25 |
| Java 25 + virtual threads | Replace SecurityContext propagation with `ScopedValue` |
| 50+ active tenants | Per-tenant scheduled job parallelization |
| First annual pepper rotation | Implement versioned token pepper (`v1:...`, `v2:...`) |
| Audit log > 1 GB | Audit log partitioning (monthly partitions) |
| Outbox > 5 GB | Outbox table partitioning + archival to S3 |
| Self-hosted Sentry preferred | Migrate from Sentry SaaS to self-hosted (data sovereignty) |
| OpenTelemetry collector deployed | Switch OTLP exporter from noop to real |
| Spring Boot major version | Boot 5 evaluation (when released) |
| First paying customer | Register `.com.tr` domain; wildcard SSL |
| First paying customer | Argon2id migration for password hashes |
| Wildcard SSL ready | Subdomain-based tenant resolution (per ADR-013) |
| Storage > 8 GB | Migrate document storage LocalFS → R2/S3 |
| Storage migrated to S3 | Switch document downloads to signed URLs |

### Product features

#### v1.1 (3–6 months after launch)

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
- Offline POS (the hardest single feature; dedicated sub-roadmap).
- MFA activation (TOTP, schema already deployed).
- Rate limiting moved from in-memory Bucket4j → PostgreSQL bridge for multi-instance.
- Tenant tier-based metric tagging (low cardinality).
- k6 performance test suite.
- English UI translation (i18n already in place).
- Mantine v9 evaluation when released.
- Vite major version upgrade when stable.

#### v2 (12 months+)

- Multi-currency cash registers.
- Jewellery module (gramaj / ayar / live gold rates / piece-level serials / workmanship).
- Cafe / restaurant module (recipes, tables, KDS, hesap bölme).
- Mobile companion app (owner dashboard + cashier mobile POS).
- e-commerce integrations (Trendyol, Hepsiburada, Shopify).
- Accounting software exports (Logo, Mikro).
- Multi-region deployment, data residency options.
- Custom report builder.
- Zone/bin-scoped parallel counts.
- Maven multi-module structure split.
- Microservices extraction (only if proven scale need).

---

## Quality Gates

Each sprint must pass these gates before merging:

| Gate | Check |
|---|---|
| RLS coverage | Every new tenant table has RLS policy + cross-tenant leak test (parametrized) |
| Append-only enforcement | New ledger tables enforce immutability (UPDATE/DELETE raises) |
| Idempotency (write side) | Every state-changing endpoint affecting money/stock has idempotency test |
| Idempotency (consumer side) | Every outbox consumer writes `processed_events` row in same TX as projection; tested under duplicate delivery |
| Atomic transactions | Hot-path operations have "kill mid-transaction" test verifying clean state |
| Outbox envelope | Every produced event conforms to envelope (`domain-events.md`); CI lint validates schema |
| Outbox event coverage | Every cross-context state change has an outbox event with consumer (or documented stub) |
| Stream separation | Security events go to `security_audit_log`, not `outbox_events` |
| Replay / rebuild | Every projection has `rebuild_*` command exercised in test |
| DLQ handling | New failure modes map to `dead_letter_reason`; DLQ size/age monitored |
| Audit | Critical operations produce dedicated audit events |
| Migration linting | CI rejects migrations without tenant_id + RLS for tenant tables |
| External I/O outside TX | ArchUnit rule (ADR-017) catches HTTP/storage clients inside `@Transactional` |
| Worker pattern | New workers use 3-bean ClaimService/Generator/Finalizer split |
| Aggregate ownership | ArchUnit rule (ADR-012) catches cross-module repository access |
| Service family discipline | LifecycleServices do not call other modules' APIs |
| Orchestrator size | CompletionOrchestrators ≤ 5 public methods and ≤ 800 LOC |
| ArchUnit | All 20+ rules pass (CI gate) |
| Spring Modulith | `ApplicationModules.verify()` passes (CI gate) |
| JSONB typing | Core-domain JSONB columns use typed records, not raw Map (ArchUnit) |
| PII discipline | Log capture tests verify email/name/phone never appear in app logs |
| Coverage | Backend 60% overall, 80% in sales/inventory/financial; Frontend 60% overall, 80% in pos/auth |
| Playwright smoke | 3+ E2E smoke tests pass on every release candidate |

---

## Risks and Mitigations

| Risk | Mitigation |
|---|---|
| RLS misconfiguration leaks tenant data | CI lint + parametrized cross-tenant test suite + sentinel UUID defense |
| Outbox publisher falls behind | Monitoring on publisher lag; alert on PENDING > 1000 events |
| Dead-letter queue accumulation | Monitoring; `OutboxEventDeadLettered` events drive alerts |
| Ledger projection drift | Nightly reconciliation; **no auto-rebuild** — human triages |
| Saga partial outcomes | Process-instance state in admin dashboards; manual reconciliation queue |
| Consumer non-idempotency | Mandatory `processed_events` write in same TX; tested under duplicate delivery |
| Event-schema drift | Schema validation producer+consumer; mismatch → DLQ with `SCHEMA_MISMATCH` |
| POS feels slow due to lock contention | Canonical lock order + targeted indexes; load testing |
| External I/O blocks DB pool | TX1/External/TX2 pattern (ADR-017); ArchUnit rule; pool monitoring |
| Token pepper compromise | Force-logout-all runbook documented; versioned pepper roadmap entry |
| Sentry SaaS retention loss (30d) | Critical issues triaged within 24-48h; long-term audit lives in DB |
| Neon Free tier 0.5 GB exhaustion | Outbox PUBLISHED cleanup nightly; audit partitioning v1.1+; upgrade trigger documented |
| Fly.io outage during pilot | Migration runbook to Hetzner CX22 ready; weekly backup off-site on R2 |
| e-Belge integration delays | Schema decoupled from provider; submission async; manual fallback documented |
| Scope creep (sectoral expansion in MVP) | Strategy locked: clothing/boutique only for MVP |
| PII anonymization regret | ADR-009 reversibility opt-in with contractual gating |

---

## What Is Explicitly Out of Scope for MVP

- Offline POS (v1.1).
- Mobile applications (v2).
- e-Commerce marketplace integrations (v2).
- Multi-currency cash registers (v2).
- Jewellery / cafe modules (v2).
- Custom report builder (v2).
- Multi-region deployment (v2 if ever).
- Real-time inventory sync across tenants (v2 if ever).
- Server-side rendering / Next.js (not needed).
- Microservices extraction (revisit only on proven scale need).
- Kubernetes (docker-compose / Fly.io sufficient through 25-customer scale).

Carrying these explicitly prevents architecture creep during MVP execution.
