# Phase 3.A — POS Flow

> **Status:** Locked
> **Phase:** 3.A
> **Delivery date:** 2026-05-16

This is the most critical sub-phase of Phase 3. POS Flow defines the cashier's primary workflow: from idle terminal to completed sale, including all error recovery paths.

Every other Phase 3 sub-phase builds on patterns established here (keyboard-first navigation, scanner integration, server-authoritative state, manager override flow, idempotency discipline, mutation-state lock).

## Screens (7)

| # | Screen | Purpose | Key complexity |
|---|---|---|---|
| 3.A.1 | POS Main Sale | Cashier's home; build cart via barcode or search | Pre-cart → DRAFT two-phase persistence; client_cart_id |
| 3.A.2 | Product Search Modal (F1) | Find product when barcode unavailable | Flat variant list; scanner auto-close + forward |
| 3.A.3 | Customer Select Modal (F2) | Attach Party to Sale | Phone last-7 search; phone masking permission |
| 3.A.3.b | Quick Customer Create | Minimal new customer inline | Duplicate phone → "use existing only" |
| 3.A.4 | Discount Modal (F3) | Line or cart-wide discount | Manager override token with full action binding |
| 3.A.5 | Payment Screen | Multi-tender collection + Sale.complete | Mutation lock at AWAITING_PAYMENT; X-Idempotency-Key |
| 3.A.6 | Terminal Pending / Recovery | Card terminal status + TIMEOUT handling | Manual APPROVED forbidden; manager cancel or void only |
| 3.A.7 | Completion / Receipt | Success confirmation + receipt actions | Async PDF; "queued" labels (not "done") |

## Locked decisions catalog

### Cart and Sale aggregate

- **Pre-cart vs DRAFT**: Cart held in Zustand until first item added; first item triggers `POST /sales` to create DRAFT
- **`client_cart_id`**: UUID generated client-side; idempotent replay across network failures
- **Parked sales**: MVP scope; `sales.parked_at` column; 24h retention
- **Network drop**: ky retries 2x, optimistic UI for cart edits, localStorage mirror for crash recovery
- **Online-only**: MVP does not support true offline; degraded online experience documented

### Scanner

- **Burst detection**: 30-50ms HID-burst window; real second scan accepted
- **Duplicate scans**: All trusted (no silent ignore); only HID hardware burst filtered
- **Audit**: Every scan logged in `pos_scan_attempts` (append-only)
- **Modal interaction**: Scanner never suspended; modal scan auto-closes + forwards to add-item pipeline
- **POS-only scope**: Scanner listener active only on /pos route

### Price authority

- **Server authoritative**: All totals computed server-side
- **Client preview**: Only raw item sum (KDV + discount + grand total come from server)
- **Snapshot strategy**: `unit_price_gross` and `original_unit_price_gross` captured at line-add; DRAFT does not re-price if admin changes price_list
- **`price_source` enum**: BASE_PRICE_LIST | MANUAL_OVERRIDE | EMPLOYEE | PRICE_MATCH | CUSTOMER_TIER (v1.1+) | PROMOTION (v1.1+)

### Discount

- **Scope resolution**: Focused line → line discount; else cart-wide
- **Stacking**: Forbidden in MVP (cart-wide ↔ line discounts mutually exclusive)
- **Types**: PERCENT, AMOUNT, OVERRIDE_PRICE (latter is separate permission + distinct semantics)
- **Override price ≠ discount**: `manualPriceOverride: boolean` separate; `original_unit_price_gross` preserved
- **Reasons**: PROMO, DAMAGED_ITEM, LOYALTY, PRICE_MATCH, MANUAL_GOODWILL, EMPLOYEE_DISCOUNT
- **EMPLOYEE_DISCOUNT**: Customer must have EMPLOYEE role
- **Reason threshold**: Tenant config (default ≤10% optional, >10% mandatory)

### Manager override

- **PIN**: 6-digit numeric, BCrypt via shared CredentialHasher
- **Lockout scope**: (tenant_id, register_session_id), 5min sliding window, 3 fails
- **`manager_pin_attempts` table**: Append-only, audit-grade, source of truth for lockout
- **Override token**: JWT signed with `static_secret + server_instance_nonce`; JVM restart invalidates
- **Token binding**: Full `approved_action` payload (type, value, scope, sale_id, line_id, reason_code)
- **Token mismatch**: 409 + `discount_override_mismatch_attempted` audit event
- **Single-use**: Pure Caffeine cache (no DB fallback) MVP; DB-backed v1.1+

### Payment

- **Tender types**: CASH, CARD, CUSTOMER_ACCOUNT (3 only; gift voucher v1.1+)
- **Mutation lock**: AWAITING_PAYMENT state forbids all pricing/quantity/customer mutations
- **Revert to DRAFT**: Allowed with confirm; APPROVED CASH and CUSTOMER_ACCOUNT reversible; APPROVED CARD blocked (back-office only)
- **Cash overpayment**: Two cash_movements (SALE_CASH_IN gross + SALE_CHANGE_OUT)
- **Credit limit override**: MVP allowed with manager PIN + reason + `credit_limit_exceeded_with_override` audit
- **Credit override reasons**: TRUSTED_REGULAR, TEMPORARY_BREACH, MANAGER_DISCRETION
- **Sale.complete idempotency**: `X-Idempotency-Key` header mandatory; `idempotency_keys` table, 7-day retention

### Terminal handling

- **Polling**: 2s interval during AWAITING_TERMINAL
- **Server-side timeout**: 90s
- **TIMEOUT resolution**: Manager cancel or void only — NO manual APPROVED
- **Cancellation states**: `CANCELLED_BY_CASHIER` vs `CANCELLED_BY_MANAGER` distinct
- **Late callback**: `SaleReconciliationRequired` event; cashier banner only if same active session; otherwise manager dashboard only
- **Late callback queue**: None (manager dashboard is source of truth for inactive cashiers)

### Completion

- **PDF generation**: Async via Phase 6.F worker pattern
- **Cashier flow**: Can press "Yeni Satış" before PDF ready
- **Print action**: "Kuyruğa alındı" 5s feedback, then button resets
- **Print retry**: 3 attempts (30s/2m/10m); manager alert on failure
- **Email action**: Same "Sıraya alındı" honest UX
- **SMS**: Removed from MVP (no UI, no endpoint)
- **PDF thumbnail**: Removed from MVP (status text + buttons only)
- **Receipt reprint**: F9 retriggers Gotenberg

## Schema additions

Migration 018 (post Phase 2E):

- `sales.client_cart_id` UNIQUE per-tenant
- `sales.parked_at` for hold-sale feature
- `sale_items.original_unit_price_gross` NOT NULL (every item captures)
- `sale_items.manual_price_override` BOOLEAN
- `sale_items.price_source` enum
- `users.manager_pin_hash`, `users.manager_pin_set_at`
- `payment_attempts.status` CHECK expanded for cancellation distinctions
- `cash_movements.movement_type` CHECK expanded for SALE_CASH_IN / SALE_CHANGE_OUT
- New table `pos_scan_attempts` (append-only audit)
- New table `manager_pin_attempts` (append-only audit; source of truth for lockout)

See `migrations/018_pos_extensions.sql`.

## Audit event catalog (Phase 3.A additions)

| Event | Triggered by |
|---|---|
| sale_proceeded_to_payment | F12 from 3.A.1 → 3.A.5 |
| sale_reverted_to_draft | "Sepete dön" from 3.A.5 |
| sale_reverted_with_approved_tenders | Revert when CASH/CUSTOMER_ACCOUNT tenders approved |
| sale_voided | Esc + confirm on empty payment or TIMEOUT manager void |
| sale_completed | Successful Sale.complete |
| tender_dispatched | Card sent to terminal |
| tender_approved | Terminal callback success |
| tender_declined | Terminal callback decline |
| tender_timeout | 90s server-side timer elapsed |
| tender_cancelled_by_cashier | Esc during AWAITING_TERMINAL |
| tender_cancelled_by_manager | TIMEOUT resolution via manager |
| tender_refunded | APPROVED tender refunded post-completion |
| sale_reconciliation_required | Late callback after CANCELLED or TIMEOUT |
| credit_limit_exceeded_with_override | Customer account tender exceeds limit |
| cash_drawer_opened | Sale completion or manual no-sale |
| sale_discount_applied | Cart-wide or line discount applied |
| sale_discount_removed | Discount removed |
| sale_line_discount_applied | Line discount applied |
| sale_line_discount_removed | Line discount removed |
| sale_line_price_overridden | Manual price override applied |
| sale_line_price_override_removed | Override removed, original price restored |
| discount_override_attempted | Manager PIN entered for discount |
| discount_override_mismatch_attempted | Token claim ≠ request payload |
| manager_pin_lockout | 3 PIN fails in 5min window |
| party_phone_unmasked | Cashier toggled phone visibility |

## API endpoints (Phase 3.A additions)

| Endpoint | Purpose |
|---|---|
| POST /sales | Create DRAFT sale (first item) |
| POST /sales/{id}/items | Add item to DRAFT |
| PATCH /sales/{id}/items/{lineId} | Change qty/price |
| DELETE /sales/{id}/items/{lineId} | Remove line |
| PATCH /sales/{id}/customer | Attach/detach customer |
| PATCH /sales/{id}/discount | Apply cart-wide discount |
| DELETE /sales/{id}/discount | Remove cart-wide discount |
| PATCH /sales/{id}/items/{lineId}/discount | Apply line discount |
| DELETE /sales/{id}/items/{lineId}/discount | Remove line discount |
| POST /sales/{id}/park | Park DRAFT sale |
| POST /sales/{id}/recall | Recall parked sale |
| POST /sales/{id}/proceed-to-payment | DRAFT → AWAITING_PAYMENT |
| POST /sales/{id}/revert-to-draft | AWAITING_PAYMENT → DRAFT |
| POST /sales/{id}/tenders | Create tender |
| DELETE /sales/{id}/tenders/{tenderId} | Cancel tender |
| POST /sales/{id}/tenders/{tenderId}/cash-confirm | Confirm cash count |
| POST /sales/{id}/tenders/{tenderId}/terminal-callback | Terminal integration callback |
| POST /sales/{id}/complete | Sale.complete (X-Idempotency-Key required) |
| POST /sales/{id}/void | Sale void |
| GET /sales/{id} | Read sale (used for polling) |
| GET /sales/{id}/document | Document status + URL |
| POST /sales/{id}/document/print | Trigger print |
| POST /sales/{id}/document/email | Trigger email |
| POST /parties/search | Customer search |
| POST /parties | Create party (quick create) |
| GET /parties/{id}/account-summary | Fresh credit info |
| POST /catalog/variants/search | Product variant search |
| GET /catalog/variants/by-barcode/{barcode} | Barcode lookup |
| POST /auth/manager-override | Issue manager override token |

Detailed OpenAPI spec generated in Phase 5.

## Open items for later phases

- Receipt template design (Phase 3.B catalog context — what fields show)
- Customer history view (Phase 3.G — Parties screen)
- Sale reversal flow (Phase 3.E — Returns)
- Reconciliation queue UI (Phase 3.K — Admin)
- Manager dashboard for late callbacks (Phase 3.K)
- "Yazıcı offline" alert routing (Phase 3.K observability)

## What's NOT in Phase 3.A scope

- Catalog management (product/variant CRUD) — Phase 3.B
- Inventory operations (stock listing, transfers, counts) — Phase 3.C
- Return / Exchange flow — Phase 3.E (referenced but not designed here)
- Cash register open/close (3.I) — referenced as preconditions only
- Reports — Phase 3.J
- Admin / settings — Phase 3.K
