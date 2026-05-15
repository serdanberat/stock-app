# Phase 1 — Product Decisions

> **Status:** Locked
> **Last updated:** 2026-05-15
> **Scope:** Multi-tenant retail ERP/POS for clothing, boutique, jewelry and accessory stores

---

## 1. Product Vision

A multi-tenant retail ERP/POS where the unit of commerce is the **variant** (Product + Color + Size + Store + Barcode), not the product. Deployable as SaaS (shared DB with `tenant_id`) or on-premise. Built from day one for multi-store, multi-currency (TRY/USD/EUR/GBP; XAU/XAG defined for v2), live FX feed, offline-capable POS (v1.1+), and e-document readiness (e-Arşiv/e-Fatura).

Three non-negotiable principles guide every design decision:

1. **The `stock_movements` ledger is the single source of truth for stock.** Current stock is never stored as a column; it is computed or projected from movements.
2. **The variant is the unit of commerce, not the product.** Barcodes, prices, costs, sale lines, purchase lines — all reference `product_variant_id`.
3. **Cost is historical and per-movement.** Each IN movement carries its own `unit_cost_try` and FX rate. Margin on a sale is computed against the cost layer consumed at the moment of sale (WAC in MVP, FIFO available in roadmap), never against today's purchase price.

---

## 2. Locked Strategic Decisions

| Decision | Choice |
|---|---|
| Strategy | Yol 3 — Start in clothing/boutique, expand to neighbouring sectors gradually |
| Primary target sectors | Clothing + Boutique (MVP), Accessories (close), Jewelry (v2) |
| Sales messaging | Owned by sales team; product team focuses on product |
| Multi-sector architecture | Light gates: `industry` + `metadata` JSONB + generic attributes + `enabled_modules` |
| Multi-tenancy | Shared DB + `tenant_id` + PostgreSQL Row-Level Security (RLS) |
| Cost method | WAC in MVP; ledger is FIFO-ready; configurable per tenant |
| Offline POS | Online-only in MVP; offline in v1.1+ |
| Localisation | Turkey first (TRY, TCMB, KDV, e-document hooks); international v2 |
| Database | PostgreSQL (RLS, JSONB, materialized views, partial indexes) |

---

## 3. Product Codification — Three-Level Code Model

Every variant carries three codes, each with its own purpose:

| Level | Field | Purpose | Required | Notes |
|---|---|---|---|---|
| Model code | `products.code` | Human-readable; "talking code" optional | Optional (system can generate) | Configurable template per tenant/category |
| Variant SKU | `product_variants.sku` | Human-readable per variant | Auto-generated, override allowed | Format: `{model_code}-{color_short}-{size}` |
| Variant barcode | `product_variant_barcodes.barcode` | Machine-scanned identifier | Required | UNIQUE per tenant |

**Smart code template (MVP):** Configurable per tenant/category. Components include `{MENSEI}`, `{YIL}`, `{KATEGORI}`, `{SIRA:N}`, `{FIYAT_KODU}`, `{SEZON}`, `{SABIT:"X"}`. Price cipher uses a 10-letter keyword scheme defined in tenant settings.

**Barcode scope categorisation:** Every barcode record carries a `barcode_scope`:

| Scope | Source | Validation | Generation |
|---|---|---|---|
| `INTERNAL` | System-generated | Format + check digit | Tenant prefix + sequence + check digit (default prefix `20`, tenant can configure `869xxxxx` if GS1 member) |
| `SUPPLIER` | Manually entered or scanned during goods receipt | Loose format | Never generated |
| `GS1_EAN` | GS1-registered codes (`869xxx`, etc.) | Strict EAN-13 + check digit | Optional self-generation if tenant has GS1 |

**Uniqueness:** `UNIQUE(tenant_id, barcode)`. No global uniqueness across tenants (deliberate — different tenants may legitimately have the same supplier barcode).

---

## 4. Product Card — Required vs Optional Fields

To balance speed of entry with completeness, only a small set of fields is mandatory:

**Required (fast card):**
- Product name
- Category (dropdown + inline create)
- Sale price
- VAT rate (defaults from tenant settings)
- At least 1 variant (color or size — at least one dimension)

**Optional (recommended but not blocking):**
- Product code (system can auto-generate from category prefix + sequence)
- Brand, season, gender, material, description
- Cost price (auto-populated from first purchase invoice)
- Min/max stock levels
- Images (product-level and variant-level, multiple)
- Default supplier

**Active/passive flag:** Defaults to active; user is not prompted.

---

## 5. Variant Limits

| Limit type | Value | Enforcement layer |
|---|---|---|
| Soft warning | 200 variants per product | Application UI (toast/info) |
| Hard reject | 500 variants per product | Domain validation (configurable per tenant plan) |

Limits are **application-level**, not DB CHECK, so tenant plans can override and import scripts can bypass with explicit flags.

Reasoning: above 200 is usually a sign of "matrix abuse" (e.g. 20 colors × 15 sizes × 8 fits × 4 materials). The system should nudge users to split into separate product families.

**Roadmap note:** Async background job for >200-variant creation in v1.1+.

---

## 6. Photos

| Aspect | Decision |
|---|---|
| Mandatory? | No |
| Per product? | Yes, multiple |
| Per variant? | Yes, multiple (e.g. one image per colour) |
| Storage | Object storage (S3-compatible); references stored in DB |

---

## 7. Multi-Store / Multi-Warehouse

Multi-store from day one. Every tenant automatically gets a system-managed virtual store of type `VIRTUAL_IN_TRANSIT` used for inter-store transfer choreography. This virtual store cannot be deleted, archived or deactivated.

---

## 8. Currency, FX and Live Rates

The single most impactful technical decision in Phase 1: FX is **not** TCMB-only. Real boutique users in Turkey already follow live market feeds (e.g. Harem) because TCMB's once-daily rate lags the actual cost of imported inventory.

**Active currencies in MVP:** TRY, USD, EUR, GBP.
**Defined but inactive in MVP, activated in v2:** XAU, XAG, XAU22, XAU14, XAU_CEYREK, XAU_YARIM, XAU_TAM, XAU_CUMHURIYET.

**FX rate sources (pluggable provider architecture):**

| Source code | Type | Status | Notes |
|---|---|---|---|
| `TCMB` | Daily | Active | Official, used for tax/accounting |
| `HAREM` | Realtime | Active | Default for pricing/buying decisions |
| `MANUAL` | On-demand | Always active | User override |
| `FOREKS` | Realtime | Infrastructure-ready, not implemented | v1.1+ |
| `GOLDISTANBUL` | Realtime | Infrastructure-ready, not implemented | v1.1+ |
| `BIGPARA` | Realtime | Infrastructure-ready, not implemented | v1.1+ |
| `DOVIZCOM` | Realtime | Infrastructure-ready, not implemented | v1.1+ |

Tenants choose their preferred source via `tenant_settings.preferred_fx_source` (defaults can be changed without code).

**Usage rules:**

| Operation | FX source |
|---|---|
| Purchase invoice post | Snapshot from live source (per tenant preference) |
| Season pricing | User selects rate (live suggested) |
| POS sale | Label TRY price (no conversion in MVP) |
| Supplier payment | Live snapshot at time of payment |
| Accounting / tax reports | TCMB (regulatory) |

**Snapshot discipline:** Every monetary line item that involves non-TRY currency carries an immutable `fx_snapshot_id`. Rates are read with timezone discipline: all timestamps stored as UTC; `tenant_timezone` snapshotted at point of capture for later display.

---

## 9. Cost Method

WAC (Weighted Average Cost) in MVP. The `stock_movements` ledger captures per-movement `unit_cost_try`, which means the same ledger trivially supports FIFO without schema change. The cost engine is replaceable per tenant via configuration (`tenant_settings.cost_method`). The **sale-time cost is frozen on `sale_items.unit_cost_try`**, so historical margins never change when the cost method is later switched.

---

## 10. User Roles (6 System Defaults)

| Role | Scope of authority | Sees costs/margins | Permissions example |
|---|---|---|---|
| Super Admin | Tenant-wide | Yes, everywhere | All permissions |
| Store Manager | Assigned stores | Yes, within own stores | Operational + returns over limit + reports |
| Cashier / Sales Associate | POS | **No** | POS, in-policy returns, lookup own sales |
| Stock Clerk / Warehouse | Goods receipt, transfers, counts | No (configurable) | Inventory operations |
| Accountant | Read-only across financials | Read-only | Reconcile payments, view current accounts |
| Auditor | Read-only everywhere | Read-only | External bookkeepers |

**Granularity:** Each permission is a `module.action` string. Roles store JSON arrays of granted permissions plus optional `store_id` scope. Custom roles can be cloned from system roles. The 6 system roles cannot be deleted or modified — only copied.

---

## 11. MVP Module List (Locked)

**Identity & Tenancy:** Tenant, users, roles & permissions, multi-store + per-user store scoping, audit log.

**Catalog:** Categories (hierarchical, max 5 levels), brands, seasons, attribute system (colors, sizes, materials, models), product cards, variants, variant matrix editor, variant barcode (with scope), variant prices (append-only history), product/variant images, price history. Pricing is inside the Catalog context as a separable aggregate.

**Inventory:** Append-only `stock_movements` ledger, current-stock projection, goods receipt, inter-store transfers (with virtual in-transit store), physical count + variance posting, stock adjustments with reason codes, low-stock alerts per variant per location, reorder suggestions [v1.1].

**Barcode:** Auto-generated EAN-13 with tenant-assigned prefix + check digit; manual supplier/GS1 entry; label printing with multiple templates; USB HID and Bluetooth scanner integration.

**Purchasing:** Suppliers, purchase invoices (multi-currency with FX snapshot), purchase returns. Purchase orders and landed cost in v1.1.

**Sales / POS:** POS sale screen, cart hold/recall [v1.1], customer attach by phone lookup, line and cart discounts, mixed payments, returns and exchanges, sales invoice generation, e-document fields reserved (integration v1.1), campaigns/loyalty/gift cards [v1.1].

**Customer & Party Management:** Unified `parties` table (customer + supplier + employee with `party_types[]` array), customer cards with phone lookup, purchase history, segments/tags [v1.1].

**Financial / Current Account:** Unified `account_movements` ledger (append-only) per `AccountProfile` (party × role × currency), payments with auto-FIFO or manual allocation, payment reversals (full or partial), credit limit checks, supplier balances with due-date tracking, statements, multi-currency balances.

**Cash & Banking:** Per-store cash registers, register sessions (open → close → Z-report), tender breakdown, day-end sealing.

**Currency / FX:** Currencies, daily and realtime rates with history (pluggable sources), `fx_snapshot` on every monetary line.

**Staff & Commission:** Salesperson attribution per sale line; commission rules and reports [v1.1].

**Reporting & Dashboards:** Daily dashboard, sales/stock/best-seller/profit reports, current-account aging, ABC/dead-stock/turnover analyses [v1.1], custom builder [v2].

**Settings:** Company profile, VAT rates with effective dates, receipt/invoice templates, hardware setup, backup/export, integration settings.

---

## 12. Versioning Roadmap (Customer-Facing Names)

| Tier | Customer name | Target window |
|---|---|---|
| MVP | Başlangıç Paketi | Launch |
| v1.1 | Profesyonel Eklentiler | 3–6 months post-launch |
| v2 | Kurumsal Paket | 12 months+ |

See `/docs/implementation/roadmap.md` for the development sequencing.

---

## 13. Open Items Carried Into Implementation

- **Pricing strategy:** Final pricing tier amounts are a draft pending competitor research (Logo, Mikro, Wolvox, Vega, Solo, Nebim, Akınsoft).
- **Hardware bundling:** Optional aggregation of label printer, scanner, receipt printer, cash drawer — pricing TBD.
- **e-Belge provider selection:** Architecture-ready, vendor not chosen.
