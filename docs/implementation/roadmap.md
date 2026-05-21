# Implementation Roadmap

> **Status:** Phase 1, 2A–2E, 6, 3.A, 3.B, 3.C, 3.D, 3.E locked. Phase 3 COMPLETE. Phase 4, 5 next.
> **Last updated:** 2026-05-21

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
| **3** | **Screen wireframes (text-mockups, 5 sub-phases)** | **✅ COMPLETE (31 screens)** |
| 4 | Backend architecture detail (module-by-module) | Next |
| 5 | API endpoint catalogue + OpenAPI | After Phase 4 |
| 7 | Implementation (12 sprints) | After Phase 5 |

### Phase 3 sub-phases — COMPLETE

| Sub-phase | Topic | Screens | Status |
|---|---|---|---|
| **3.A** | **POS Flow** | 7 | **✅ Locked** |
| **3.B** | **Catalog Management** | 6 | **✅ Locked** |
| **3.C** | **Inventory Operations** | 5 | **✅ Locked** |
| **3.D** | **Financial Flows** | 7 | **✅ Locked** |
| **3.E** | **Operational/Admin** | 6 | **✅ Locked** |
|  | **Total** | **31** |  |

### Phase 3.E deliverables (locked, this milestone)

| Screen | Doc |
|---|---|
| 3.E.1 | Cash Register Open | `screens/admin/3e1-register-open.md` |
| 3.E.2 | Cash Register Close + Z Report | `screens/admin/3e2-register-close.md` |
| 3.E.3 | User & Role Admin | `screens/admin/3e3-user-admin.md` |
| 3.E.4 | Tenant Feature Flags | `screens/admin/3e4-feature-flags.md` |
| 3.E.5 | Basic Reports | `screens/admin/3e5-reports.md` |
| 3.E.6 | Audit Log Browser | `screens/admin/3e6-audit-log.md` |
| Index | Locked decisions + schema + API endpoints | `screens/admin/README.md` |
| Migration | Admin extensions consolidated | `migrations/022_admin_extensions.sql` |

### Phase 3.D deliverables (locked, this milestone)

| Screen | Doc |
|---|---|
| 3.D.1 | Purchase Invoice List | `screens/finance/3d1-purchase-list.md` |
| 3.D.2 | Purchase Invoice Create/Edit | `screens/finance/3d2-purchase-edit.md` |
| 3.D.3 | Return/Exchange Initiate | `screens/finance/3d3-return-initiate.md` |
| 3.D.4 | Return/Exchange Process | `screens/finance/3d4-return-process.md` |
| 3.D.5 | Customer Account Detail | `screens/finance/3d5-customer-account.md` |
| 3.D.6 | Supplier Account Detail | `screens/finance/3d6-supplier-account.md` |
| 3.D.7 | Payment Collection | `screens/finance/3d7-payments.md` |
| Index | Locked decisions + schema + API endpoints | `screens/finance/README.md` |
| Migration | Finance extensions consolidated | `migrations/021_finance_extensions.sql` |

### Phase 3.C deliverables (locked, this milestone)

| Screen | Doc |
|---|---|
| 3.C.1 | Stock List | `screens/inventory/3c1-stock-list.md` |
| 3.C.2 | Stock Movement History | `screens/inventory/3c2-movements.md` |
| 3.C.3 | Stock Transfer | `screens/inventory/3c3-transfer.md` |
| 3.C.4 | Stock Count Session | `screens/inventory/3c4-count.md` |
| 3.C.5 | Stock Adjustment | `screens/inventory/3c5-adjustment.md` |
| Index | Locked decisions + schema + API endpoints | `screens/inventory/README.md` |
| ADR-020 | Correlation ID Pattern | `adr/020-correlation-id-pattern.md` |
| Migration | Inventory extensions consolidated | `migrations/020_inventory_extensions.sql` |

### Phase 3.B deliverables (locked)

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

### Phase 3.A deliverables (locked)

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

---

## Phase 3 final summary

**31 screens designed and locked across 5 sub-phases:**

| Sub-phase | Theme | Aggregate domains |
|---|---|---|
| 3.A POS | Point of sale | Sale, RegisterSession, Payment, Receipt |
| 3.B Catalog | Product structure | Product, ProductVariant, Attribute, PriceList, MissingItemRequest |
| 3.C Inventory | Stock authority | StockBalance, StockMovement, Transfer, CountSession, Adjustment |
| 3.D Financial | Money flow | PurchaseInvoice, Return, Payment, AccountMovement, StoreCreditBalance |
| 3.E Operational | Admin & audit | CashRegisterSession, ZReport, User, Role, Tenant, AuditEventLog |

**Architectural patterns established across Phase 3:**

- **DRAFT → COMMITTED atomicity**: Purchase invoices, transfers (2-phase)
- **Single-shot immutable**: Adjustments, Z reports
- **Append-only ledgers**: stock_movements, cash_movements, account_movements, audit_event_log
- **Correlation ID pattern (ADR-020)**: cross-aggregate event tracing
- **Server-authoritative pricing/financials**: never trust client computed totals
- **Three-component financial decomposition**: exchange (returned/new_sale/delta)
- **Friction-as-safety**: navigation-only routes (not inline edit) for fraud-sensitive ops
- **Authority-vs-projection disclosure**: explicit UI signals for projection-backed views
- **Manager PIN override**: closed-set reasons + free-text + 3-fail lockout per (tenant, register_session)
- **Reason codes are closed sets**: with OTHER + mandatory free-text fallback
- **Idempotency keys** on every consequential write: 7-day retention
- **Pessimistic FOR UPDATE canonical order**: aggregate → ledger → balance per Phase 2D
- **Display name composition Java-side** (ADR-019): never DB function
- **Audit summary composition Java-side**: consistent with ADR-019

**Schema additions across Phase 3**: 8+ new tables, ~30 schema modifications, ADRs 018-020 net new in Phase 3.

---

## What comes next

### Phase 4 — Module Contracts (LEAN scope)

> **Scope rationale:** Phase 3 already specifies aggregate ownership, state machines, transaction boundaries, and endpoint semantics per screen. Phase 4 is NOT a re-spec; it's the **module boundary lock** that ArchUnit will enforce. Avoid 30-page module specs; aim for ~1 page per module.

Deliverable (~15-18 pages total):

1. **Module list + Bounded Context mapping** (~1 page)
2. **Module Dependency Matrix** (CENTRAL ARTIFACT, ~1-2 pages)
   - Rows: 10 modules
   - Columns: can-depend-on-write / can-depend-on-query-only / cannot-depend-on
   - Each row maps to ArchUnit rules
3. **Per-module spec** (10 × ~1 page = 10-12 pages)
   - Package structure (`com.linxa.{module}.{subpackage}/`)
   - Aggregate roots (list, with reference to Phase 2B invariants)
   - Service layer split (Application vs Domain)
   - Repository interface contracts
   - Transaction ownership (@Transactional placement rules)
   - Outbox events emitted/consumed
   - ArchUnit rules (with comments referencing matrix row)
   - Cache invalidation hooks
4. **Shared kernel + cross-cutting** (~1-2 pages)
   - Money, TenantId, IdempotencyKey, CorrelationId
   - Common DTOs (PageRequest, ErrorResponse)
   - Event base interface
   - TenantAwareTransactionManager (already in Phase 6.B)

**Not in Phase 4 scope:**
- Aggregate root implementation code (Phase 7)
- Full service method signatures (Phase 7)
- Database query implementations (Phase 7)
- Detailed DTO field definitions (Phase 5)

### Phase 5 — Endpoint Catalogue + OpenAPI Skeleton (LEAN scope)

> **Scope rationale:** Phase 3 already lists every endpoint with method, path, auth, idempotency. Phase 5 catalogues them in one place + generates OpenAPI skeleton. Full DTO property definitions emerge from JPA entities at Phase 7.

Deliverable:

1. **Endpoint Catalogue table** (~120 endpoints across modules)
   - Method + path
   - Auth/permission codes
   - Idempotency (yes/no)
   - Request DTO name (e.g. `CreatePurchaseInvoiceRequest`)
   - Response DTO name
   - Phase 3 screen reference
2. **OpenAPI skeleton**
   - Paths section (method + path + permission tag)
   - Schemas section (DTO names only; properties marked `TODO at implementation`)
   - Tag groups (pos, catalog, inventory, finance, admin)

**Not in Phase 5 scope:**
- Full property-level OpenAPI schemas (generated from JPA at Phase 7)
- Example payloads (Phase 7 with real fixtures)

### Phase 7 — Implementation sprints

Claude Code-driven sprint plan. Sprint 1: repository skeleton + Identity module. Subsequent sprints follow domain dependency order (Catalog → Inventory → Pricing → Sales/POS → Purchasing → Finance → Cash → Reporting → Admin).

---

## ADRs to date

| # | Topic | Phase |
|---|---|---|
| 001 | Multi-tenancy pattern (shared DB + RLS) | 1 |
| 002 | Append-only ledger discipline | 2B |
| 003 | WAC cost methodology | 2B |
| 004 | State machine enforcement | 2C |
| 005 | Outbox pattern | 2D |
| 006 | Domain event versioning | 2D |
| 007 | RLS context propagation | 2D |
| 008 | Idempotency key strategy | 2D |
| 009 | Saga compensation policy | 2D |
| 010 | Java + Spring Boot stack | 6.A |
| 011 | JPA + JOOQ hybrid | 6.B |
| 012 | Tenant-aware transaction manager | 6.B |
| 013 | JWT HS256 + BCrypt 12 | 6.C |
| 014 | Frontend stack | 6.E |
| 015 | DocumentStorage abstraction | 6.F |
| 016 | Spring @Scheduled + ShedLock | 6.G |
| 017 | External I/O outside transactions | (overlay) |
| 018 | Pricing Resolution Strategy | 3.B |
| 019 | Display Name Composition Strategy | 3.B |
| **020** | **Correlation ID Pattern** | **3.C** |

---

## Phase 3.F — Refinements (✅ APPLIED 2026-05-21)

> **Status:** ✅ Applied to admin spec files + migration 023
> **Source:** Phase 3.E review correction notes
> **Applied:** 2026-05-21 (Phase 4 kickoff session)

8 corrections from Phase 3.E review have been integrated into the 5 admin spec files and a patch migration. These are surgical clarifications — wording, explicit invariants, snapshot policy — not architectural changes.

### 3.F.1 — Cash Register Close: invert mental model

**File to update:** `docs/screens/admin/3e2-register-close.md`

**Change:** Replace `cash_removed_amount` field with `remaining_float_amount` (kasada bırakılacak nakit).

**Rationale:** Cashier mental model is "what stays in the drawer," not "what I'm taking out." Removed amount = expected_cash − remaining_float (system computes). Eliminates ambiguity between safe deposit / bank transfer / next-day float — all of which are operationally distinct but undifferentiated in MVP.

**Schema impact:** rename column in `cash_movements` for CLOSING_DEPOSIT entries; migration patch in Phase 4 kickoff. Internal_label `CLOSING_DEPOSIT` retained (movement type semantically unchanged).

**UI change:** label "Bankaya yatırılacak (opsiyonel)" → "Kasada bırakılacak nakit"; computed display "Çıkacak nakit: ₺X.XXX" derived.

### 3.F.2 — Z report PDF byte-determinism

**File to update:** `docs/screens/admin/3e2-register-close.md`

**Add explicit invariant:** Z report PDF generation MUST NOT embed render timestamps, generation request IDs, or any non-payload-derived dynamic content. Otherwise "same payload → identical bytes" claim fails.

**Implementation rule:** PDF generator (Phase 6.F worker) reads ONLY `snapshot_payload` JSONB. Any timestamp in the rendered PDF must come FROM the payload (e.g. session.closed_at) — never from `now()` at render time.

**Test requirement (Phase 7):** byte-identical reprint test in CI — generate twice from same payload, assert SHA256 equal.

### 3.F.3 — User role model: deny semantics explicitly absent

**File to update:** `docs/screens/admin/3e3-user-admin.md`

**Add explicit invariant:**
```
effective_permissions = UNION(all assigned role permissions)
```

No deny rules. No override semantics. Multi-role is purely additive in MVP. This is a documented constraint, not an oversight.

**v1.1+ consideration:** if business needs role denial rules (e.g. "AUDITOR explicitly blocks write permissions even if combined with STORE_MANAGER"), introduce a separate `role_deny_rules` table with explicit precedence — not implicit role ordering.

**Rationale:** prevents future debate "if a user is CASHIER + AUDITOR, what wins?" with the clear MVP answer: both grant; nothing denies. No surprise.

### 3.F.4 — Tenant settings: operation-start snapshot

**File to update:** `docs/screens/admin/3e4-feature-flags.md`

**Sharpen the existing statement:** "Changes effective immediately for new operations; in-flight operations use captured config at start" needs explicit linkage to specific flows.

**Add explicit rule:**

| Setting | When captured | Where snapshotted |
|---|---|---|
| `requires_reason_above_pct` | Sale aggregate creation (open draft) | sale.threshold_snapshot |
| `max_cart_discount_pct_default` | Sale draft creation | sale.cart_discount_limit_snapshot |
| `max_line_discount_pct_default` | Sale draft creation | sale.line_discount_limit_snapshot |
| `return_window_days` | Return.initiate() | return.window_snapshot |
| `adjustment_large_threshold` | Adjustment.create() | adjustment.large_threshold_snapshot |
| `cash_variance_tolerance` | Session.open() | session.variance_tolerance_snapshot |
| `cash_variance_large_threshold` | Session.open() | session.variance_large_threshold_snapshot |

**Rationale:** mid-operation policy change must not retroactively invalidate in-flight work. Open POS sale with %30 discount mid-flow must not break when manager tightens cart_discount to %10 in another tab. Snapshot at operation start guarantees determinism.

**Schema impact:** add snapshot columns to: `sales`, `returns`, `adjustments`, `cash_register_sessions`. Phase 4 kickoff migration.

**Pricing decisions excluded:** pricing already snapshot-frozen per ADR-018 (line.unit_price_gross frozen at add-to-cart). This adds policy snapshotting alongside.

### 3.F.5 — Reports: refresh button bypasses cache

**File to update:** `docs/screens/admin/3e5-reports.md`

**Add explicit behavior:** `[⟳ Yenile]` button issues request with `Cache-Control: no-cache` header (or `?fresh=true` query param). Server bypasses 5-min Caffeine cache for explicit refresh requests; updates cache with new result.

**UX impact:** "Veriler: 14:32'de yenilendi" timestamp updates to now after refresh click.

**Rationale:** stale cache hit on refresh click is a worse UX than slightly slow refresh. Cache is for unprompted views; explicit user intent bypasses.

### 3.F.6 — Audit log retention policy

**File to update:** `docs/screens/admin/3e6-audit-log.md`

**Add explicit policy:** Audit events retained **minimum 5 years** for tenant. No deletion endpoint. No automatic purge MVP.

**Rationale:** Turkish tax authority (VUK) and commercial code require 5-year retention for accounting records. Audit log feeds compliance investigation. Adding retention policy later requires backfill — adding it now (even with no purge job) sets the contract.

**Storage implication:** ~1-5 MB/store/year audit events at typical retail volume. 5-year × 100 stores = 500MB-2.5GB. Negligible. PostgreSQL TOAST handles JSONB payloads well.

**v1.1+ consideration:** archival tier (Neon → S3 Glacier-equivalent) for events > 2 years old. MVP keeps everything hot.

### 3.F.7 — STORE_MANAGER editing scope: explicit allowlist

**File to update:** `docs/screens/admin/3e3-user-admin.md`

**Replace ambiguous "limited fields" with explicit matrix:**

| Operation | STORE_MANAGER | SUPER_ADMIN |
|---|---|---|
| Activate/deactivate cashier (own store) | ✓ | ✓ |
| Reset cashier password | ✗ | ✓ |
| Reset manager PIN (own store users) | ✓ | ✓ |
| Edit user display_name (own store users) | ✓ | ✓ |
| Change user email | ✗ | ✓ |
| Assign roles | ✗ | ✓ |
| Assign stores | ✗ | ✓ |
| Create user | ✗ | ✓ |
| Delete user | ✗ (deactivate only) | ✗ (deactivate only) |

**Rationale:** STORE_MANAGER scope is operational user lifecycle for own store (activate/deactivate/PIN reset). Identity (email) and authorization (role/store assignment) are SUPER_ADMIN territory. This prevents privilege escalation via "STORE_MANAGER promotes self to SUPER_ADMIN" attack surface.

**Server enforcement:** field-level permission check in PATCH endpoint; not just route-level. STORE_MANAGER PATCH with `roles` field in body → 403.

### 3.F.8 — Audit log browser: PII masking for non-AUDITOR

**File to update:** `docs/screens/admin/3e6-audit-log.md`

**Add explicit rule:** When `audit.view` granted to STORE_MANAGER (tenant config option), PII fields in event payload masked unless user also has `parties.view_full_phone` / `parties.view_full_email`.

**Masking pattern (consistent with 3.A.3):**
- Phone: `0532 *** 1234` (first 4 + last 4)
- Email: `a***t@example.com` (first char + last char of local-part)
- Full name: NOT masked (operational necessity; "Ayşe Y." truncation only by length)

**AUDITOR + SUPER_ADMIN see full PII** (these roles by definition have full data access).

**Rationale:** audit screen shows sensitive event payloads; STORE_MANAGER browsing own-store events doesn't need to see customer phones in plain text. Defense-in-depth: tenant data exposure scope follows least-privilege.

**Implementation:** `AuditEventSummaryComposer` and raw-JSON expansion both apply masking transform based on viewer's effective permissions.

---

## Phase 3 status — kapanış

Phase 3 design phase is closed. 31 screens, 5 sub-phases, 3 ADRs net new (018-020). Phase 3.F refinements (8 corrections) applied 2026-05-21.

**Next milestone**: Phase 4 — Module Contracts (focused scope per Phase 4 lean approach):
- Module list + bounded context mapping
- **Module dependency matrix** (central artifact)
- Per-module spec (~1 page each: package structure, aggregate roots, service split, transaction ownership, outbox events, ArchUnit rules)
- Shared kernel + cross-cutting

After Phase 4: Phase 5 endpoint catalogue + OpenAPI skeleton, then direct to Phase 7 implementation (Claude Code).

