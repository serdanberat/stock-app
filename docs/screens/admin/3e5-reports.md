# 3.E.5 — Basic Reports

> **Status:** Locked (Phase 3.E)
> **Routes:**
> - `/reports` — Index
> - `/reports/sales-summary`
> - `/reports/stock-valuation`
> - `/reports/top-selling`
> - `/reports/customer-aging`
> - `/reports/markup-analysis`

## Purpose

5 essential reports. Read-only. CSV export for accountant workflow.

## Five reports

### 1. Sales Summary
- Period (day/week/month/custom)
- Store filter
- Breakdown: by tender, by day, by category
- Returns: `total_sales, total_refunds, net_revenue, by_tender, by_category, sale_count`

### 2. Stock Valuation
- Snapshot timestamp (current or as-of date)
- Per store + per category
- Value = quantity × WAC
- **Snapshot timestamp prominently displayed (mview staleness disclosure)**

### 3. Top Selling Variants
- Period filter
- Top N (default 20)
- Category filter
- Sort by: `units_sold` or `revenue`

### 4. Customer Aging
- Per customer breakdown 0-30/30-60/60-90/90+
- Top N defaulters
- Total outstanding

### 5. Markup Analysis (NOT "Margin")
- Per category and per variant
- Formula: `(sale_price - WAC) / WAC × 100`
- Tooltip explains formula
- Period filter

## CSV export

Each report has [CSV İndir] button.

- Generated server-side via document worker (Phase 6.F)
- UTF-8 BOM for Excel compatibility (Türkçe karakterler)
- Filename: `report-{type}-{period}-{generated_at}.csv`

## Permissions

| Permission | Default |
|---|---|
| `reports.view_sales` | STORE_MANAGER+, ACCOUNTANT+ |
| `reports.view_stock_valuation` | STORE_MANAGER+, ACCOUNTANT+, AUDITOR |
| `reports.view_markup` | STORE_MANAGER+ (with view_cost), ACCOUNTANT+ |
| `reports.view_customer_aging` | STORE_MANAGER+, ACCOUNTANT+ |
| `reports.export_csv` | Same as respective view |

## Snapshot timestamp disclosure

Consistent with 3.B.1, 3.C.1 patterns. Each report header:

```
"Veriler: 14:32'de yenilendi · [⟳ Yenile]"
```

### Refresh button — cache bypass

The `[⟳ Yenile]` button issues request with `Cache-Control: no-cache` header (or `?fresh=true` query param). Server bypasses 5-min Caffeine cache for explicit refresh requests; updates cache with new result.

**UX behavior**:
- Click [⟳ Yenile]
- Loading indicator
- Fresh data returned (cache miss intentional)
- "Veriler: 14:32'de yenilendi" timestamp updates to new fetch time
- Cache populated with fresh result (subsequent unprompted views hit cache)

**Rationale**: stale cache hit on refresh click is a worse UX than slightly slow refresh. Cache is for unprompted views; explicit user intent (refresh click) bypasses.

Stock valuation specifically:
```
"Stok değeri projection'dan alınmıştır. Anlık tutarsızlık ~1-2dk."
```

## Layout — index

```
┌─ Reports Shell ───────────────────────────────────────────────────┐
│                                                                    │
│  ┌─ Sales Summary ────────────────┐  ┌─ Stock Valuation ──────┐  │
│  │ Period: this month             │  │ As of: now              │  │
│  │ Total: ₺ 87.230                │  │ Value: ₺ 245.000        │  │
│  │ [Detay →]                      │  │ [Detay →]                │  │
│  └────────────────────────────────┘  └──────────────────────────┘  │
│                                                                    │
│  ┌─ Top Selling ─────────────────┐  ┌─ Customer Aging ──────┐    │
│  │ This month, all stores         │  │ Total: ₺ 12.450        │    │
│  │ #1 T-shirt Basic Black (45)    │  │ 90+ gün: ₺ 1.200       │    │
│  │ [Detay →]                      │  │ [Detay →]                │    │
│  └────────────────────────────────┘  └──────────────────────────┘  │
│                                                                    │
│  ┌─ Markup Analysis ─────────────┐                                │
│  │ Average: %65                   │                                │
│  │ Below cost lines: 3            │                                │
│  │ [Detay →]                      │                                │
│  └────────────────────────────────┘                                │
│                                                                    │
└────────────────────────────────────────────────────────────────────┘
```

## Implementation notes

- Reports compute server-side; cache 5min Caffeine
- CSV via worker pattern (Phase 6.F)
- No PDF or Excel MVP (CSV sufficient for accountant Excel import)
- Each report own table view with filters + export button
- Top N defaults: 20 (configurable per report)
- "Markup" wording strictly enforced (Margin tooltip warns when discussed in docs/help text)
