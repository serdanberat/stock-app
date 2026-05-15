# Bounded Contexts

> **Status:** Locked (Phase 2A)
> **Last updated:** 2026-05-15

The system is composed of **11 bounded contexts** plus cross-cutting infrastructure. Each context owns its data and exposes a well-defined API. Cross-context communication flows either through synchronous service calls (within the same atomic transaction) or asynchronously via the outbox pattern.

---

## Context Map

```
                    ┌─────────────────────┐
                    │  Identity & Tenancy │ ◄── Every context reads (auth/who/scope)
                    └─────────────────────┘
                              │
        ┌─────────────────────┼─────────────────────┐
        ▼                     ▼                     ▼
  ┌──────────┐         ┌──────────┐          ┌──────────┐
  │ Catalog  │◄────────│Purchasing│          │  Sales   │
  │(+Pricing │         │          │          │ +Return  │
  │ inside)  │         └──────────┘          └──────────┘
  └──────────┘               │                     │
        ▲                     │                     │
        │  variant lookup     │ GoodsReceived       │ SaleCompleted
        │                     ▼                     ▼
        │              ┌─────────────────────────────┐
        └──────────────│       Inventory             │
                       │  (stock_movements ledger)   │
                       └─────────────────────────────┘
                              │
              ┌───────────────┼───────────────┐
              ▼               ▼               ▼
        ┌──────────┐    ┌──────────┐    ┌──────────┐
        │  Party   │    │Financial │    │  Cash    │
        │(unified) │◄───│ +Profile │◄───│ Register │
        └──────────┘    └──────────┘    └──────────┘
                              ▲
                              │
                       ┌──────────┐
                       │    FX    │  ◄── Purchasing, Sales, Financial read
                       └──────────┘

  ┌──────────┐    ┌──────────┐
  │  Audit   │    │Reporting │  ◄── All contexts → read models / event sinks
  └──────────┘    └──────────┘
       ▲
       │  All contexts write (side effect, cross-cutting infrastructure)
```

---

## 1. Identity & Tenancy

**Purpose:** Who is using the system, from which company, in which store, with what permissions.

**Owned concepts:** Tenant, User, Role, Permission, Store (incl. virtual in-transit), UserStoreAccess.

**Boundary discipline:** Authentication and authorisation only. Resolves `(tenant_id, user_id, current_store_id)` and hands off to other contexts. Does not own user sessions — `UserSession`, tokens, MFA, password hashes are **auth infrastructure**, not domain entities.

**What others expect:** "Who made this request, from which store, what are they allowed to do?"

---

## 2. Catalog

**Purpose:** Define what can be sold — products, variants, attributes, prices.

**Owned concepts:** Product, ProductVariant, ProductVariantBarcode, Category, Brand, Season, Attribute & AttributeValue, ProductImage, VariantImage, PriceList, VariantPrice (append-only), BarcodePolicy, ProductCodeTemplate, PriceCipherKey.

**Pricing-as-aggregate inside Catalog:** `PricingPolicy` is a separate aggregate inside Catalog. v1.1 may split it into a dedicated Pricing context; the `PricingService` contract is designed so that callers (Sales) do not have to change.

**Boundary discipline:** No quantities, no real costs. Sale price is exposed only through `PricingService.getEffectivePrice()`.

**What others expect:** "I scanned this barcode — which variant is it, what is its current price, what is its VAT rate?"

---

## 3. Inventory

**Purpose:** The single source of truth for stock.

**Owned concepts:** StockMovement (append-only ledger — the heart of the system), StockBalance (projection), AverageCost (variant × location), Transfer, CountSession, CountItem, StockAdjustment, ReorderLevel, StockAlert, ReasonCode.

**Boundary discipline:** Only `InventoryService.recordMovement(...)` may write to `stock_movements`. Sales, Purchasing, Returns, Transfers — all of them call this single entry point. Direct INSERT is disallowed.

**What others expect:**
- Sales: "Am I allowed to sell this variant? What is its current avg cost?"
- Purchasing: "I received goods — record the IN movement with this cost."
- Reporting: "How much stock of this category exists in store A?"

---

## 4. Sales (Sales + Return)

**Purpose:** Sales transactions, returns, exchanges.

**Owned concepts:** Sale (aggregate), SaleItem, SalePayment, PaymentAttempt, SaleDocument; Return (separate aggregate, same context), ReturnItem, ReturnRefundDetail.

**Boundary discipline:** Sale and Return are separate aggregate roots with different lifecycles. Exchange is **not** an aggregate — it is a Return + a new Sale linked by `exchange_group_id`. Returns support a blind mode (no original sale) governed by tenant-level anti-fraud limits.

**What others expect:**
- Inventory: receives OUT movements on sale completion and IN movements on return completion.
- Financial: receives debits/credits on partial payments.
- Cash Register: receives cash/card/transfer movements.

---

## 5. Purchasing

**Purpose:** Goods receipt and supplier interactions.

**Owned concepts:** PurchaseInvoice, PurchaseInvoiceItem, PurchaseReturn, PurchaseReturnItem, LandedCost [v1.1], PurchaseOrder [v1.1].

**Boundary discipline:** Owns the document, not the side effects. On post, calls Inventory (IN movements) and Financial (supplier debit) within the same atomic transaction. FX snapshot is mandatory for non-TRY invoices.

---

## 6. Party

**Purpose:** Identity, contact and tax data for customers, suppliers and employees.

**Owned concepts:** Party (`party_types[]` array — same row may be customer AND supplier), PartyContact (separate table for flexibility), PartyDocument, PartyTag [v1.1], PartyMetadata (JSONB).

**Boundary discipline:** Identity/contact/tax only. Financial rules (`credit_limit`, `payment_terms_days`, `account_status`) live in the Financial context's `AccountProfile`. PartyContact is intentionally a separate table — never `phone1, phone2, address1` columns.

---

## 7. Financial / Current Account

**Purpose:** Track who owes what, in what currency, under what terms.

**Owned concepts:**

| Concept | Type | Notes |
|---|---|---|
| AccountProfile | Aggregate root | One per `(tenant, party, role, currency)`. Owns `credit_limit`, `payment_terms_days`, `account_status`. |
| AccountMovement | Entity (not aggregate root) | Immutable journal entry. Lives inside Payment / Sale / PurchaseInvoice transactions. Stored in table `account_movements`. |
| Payment | Aggregate root | RECEIVED or MADE, with FIFO/manual allocations, supports full and partial reversals. |
| PaymentAllocation | Entity | Links payment to specific `account_movements` rows it settles. |
| AccountBalance | Projection (not aggregate) | Materialised from `account_movements`. |
| AccountAging | Projection | Nightly recompute. |

**Boundary discipline:** Mirrors the Inventory pattern — append-only ledger + projection. Multi-currency balances are tracked per currency (never auto-converted to TRY).

---

## 8. Cash Register

**Purpose:** Physical till — opening float, movements, day-end seal.

**Owned concepts:** CashRegister (the physical till), RegisterSession (a day's open/close cycle), CashMovement, ZReport.

**Boundary discipline:** Physical, session-bound, separate from Financial. Financial answers "what does the customer owe?"; Cash Register answers "how much cash is physically in this till right now?".

---

## 9. FX (Currency)

**Purpose:** Define currencies, fetch rates, snapshot rates on documents.

**Owned concepts:** Currency, FxRateSource (pluggable provider), FxRate (append-only history per source), FxSnapshot (immutable rate lock on a transaction).

**Boundary discipline:** Pluggable provider architecture — `TCMB`, `HAREM`, `MANUAL` active in MVP; `FOREKS`, `GOLDISTANBUL`, `BIGPARA`, `DOVIZCOM` infrastructure-ready, not implemented.

---

## 10. Reporting

**Purpose:** Read-only dashboards, reports, projections.

**Owned concepts:** None as aggregates. Only materialised views, query services, projectors.

**Boundary discipline:** Never writes domain data. Subscribes to outbox events, updates materialised views. Eventually consistent. v1.1+ may route to a read replica.

---

## 11. Audit (Cross-Cutting Infrastructure)

**Purpose:** Capture every state-changing action.

**Implementation layer:** Platform infrastructure, **not** a bounded context.

Three capture layers, all of which keep domain code clean of any audit imports:

1. HTTP middleware — every API call: actor, IP, endpoint, request shape, response status, duration.
2. Domain event listener — subscribes to outbox events; records aggregate state changes.
3. Database CDC — PostgreSQL triggers or row-history tables on critical tables only.

**Critical boundary:** Domain code has **zero** audit dependencies. Audit is observed from the outside.

---

## Cross-Cutting Principles

1. **Single writer per entity.** One context, one writer. Other contexts read by reference (ID).
2. **Cross-context communication is event-driven or service-call-driven.** Never JOIN across context tables.
3. **Eventual consistency is acceptable for projections, not for money or stock.** Sale completion writes Sale + Stock + Cash + Account atomically; reporting refresh may lag a few seconds.
4. **Bounded context = bounded model.** The same concept (e.g. "customer") may have different models in different contexts; they are linked by ID, not by shared rows.
5. **Stable boundaries, flexible internals.** A context's external API is stable; its internal tables can be refactored without breaking other contexts.
