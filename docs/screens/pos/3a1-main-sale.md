# 3.A.1 — POS Main Sale Screen

> **Status:** Locked (Phase 3.A)
> **Route:** `/pos`
> **Default landing for role:** CASHIER

## Purpose

The cashier's home screen. Builds a Sale aggregate in DRAFT state by adding items via barcode scan or product search. No mouse required. Optimized for ≥60 sales/hour throughput per cashier.

## Aggregate state

- **Pre-cart**: Zustand only (no Sale row in DB yet)
- **First item added**: `POST /sales` → DRAFT row created server-side
- **Subsequent items**: `PATCH /sales/{id}/items` (server is source of truth)

### Why two-phase

Idle empty cart (cashier at register but no customer) should NOT create DRAFT rows. Otherwise we accumulate thousands of abandoned DRAFTs per day. Only commit to server when intent is clear (item 1).

## Reads

| Endpoint | When |
|---|---|
| `GET /catalog/variants/by-barcode/{barcode}` | Each scan |
| `GET /catalog/variants/search?q=...` | F1 search modal (3.A.2) |
| `GET /inventory/stock-balances/{variantId}/{storeId}` | Stock check pre-cart-add |
| `GET /sales/{id}` | Focus restore after tab switch / reload |
| Register session (Zustand) | Loaded on POS entry |

## Writes

| Endpoint | Trigger |
|---|---|
| `POST /sales` | First item added (creates DRAFT with `client_cart_id`) |
| `POST /sales/{id}/items` | Add item |
| `DELETE /sales/{id}/items/{lineId}` | Remove line |
| `PATCH /sales/{id}/items/{lineId}` | Change qty / discount |
| `PATCH /sales/{id}/customer` | Set/clear customer |
| `PATCH /sales/{id}/discount` | Cart-wide discount |
| `POST /sales/{id}/park` | Park sale (F4) |
| `POST /sales/{id}/proceed-to-payment` | → AWAITING_PAYMENT |
| `POST /sales/{id}/void` | Abandon (Esc) |

## Optimistic UI

| Action | Optimistic? |
|---|---|
| Add item | Yes |
| Remove line | Yes |
| Change quantity | Yes |
| Apply line discount | No (fraud-sensitive, see 3.A.4) |
| Apply cart discount | No (fraud-sensitive, see 3.A.4) |
| Set customer | Yes |
| Proceed to payment | No (atomic state transition) |

## Locking

- None on cart edits (DRAFT is single-cashier owned)
- Pessimistic lock on `stock_balances` only during Sale.complete (3.A.5)
- Optimistic `version` check on Sale aggregate

## Draft autosave

- Every mutation persisted immediately (no debounce on item/customer)
- Quantity +/- debounced 200ms (spam protection)
- Line price/discount typing debounced 400ms
- F12 (proceed) **flushes pending batched mutations first**
- Network failures: cart in Zustand + localStorage; sync resumes on reconnect

## Keyboard flow

### Idle (no modal, no focus)

- Global barcode buffer active; typing barcode + Enter commits
- All function keys active

### Function keys

| Key | Action |
|---|---|
| F1 | Product search modal (3.A.2) |
| F2 | Customer select modal (3.A.3) |
| F3 | Discount modal (3.A.4) |
| F4 | Park current sale |
| F5 | Recall parked sales list |
| F8 | Open cash drawer (no-sale; permission-gated) |
| F9 | Reprint last receipt |
| F12 | Proceed to payment (3.A.5) |
| Esc | Cancel/clear cart (confirm if non-empty) |

### Within cart list

| Key | Action |
|---|---|
| ↑ / ↓ | Move line focus |
| Del | Remove focused line |
| + / - | Increment/decrement focused line quantity |
| Enter | Edit focused line quantity (inline NumberInput) |
| Tab | Cart → keypad → footer buttons |

## Barcode flow

### Detection

- HID scanner = keyboard input. Hook listens at document level when route is `/pos` and no `<input>` has focus.
- Buffer accumulates keystrokes faster than 30ms apart.
- Idle gap > 100ms = end of barcode (implicit Enter).
- Minimum length 4 chars before lookup.

### Duplicate handling

- HID burst filter only (30-50ms window): hardware double-emit suppressed
- Real second scan **always accepted** (cashier may genuinely scan two of same item)
- Every scan logged in `pos_scan_attempts` (audit-grade)

### Unknown barcode

- Inline non-blocking toast: `Barkod bulunamadı: {code}`
- Audio cue (configurable per cashier, off by default)
- Cart unchanged

### Out-of-stock barcode

- If `allow_negative_stock=false` (default): modal "Stok yetersiz — yine de ekle? (Manager override)"
- If `allow_negative_stock=true`: add with warning badge on line

## Speed budget (cashier-perceived)

| Action | p95 target |
|---|---|
| Scan to cart line visible | < 150ms |
| Cart total recalc (client) | < 50ms |
| Add item server confirm | < 400ms |
| Proceed to payment | < 600ms |

## Permissions

- `sales.create` (required to access POS)
- `cashregister.open_drawer` (F8)
- `sales.override_price` (line price manual override)
- `sales.discount.high_value` (cart-wide discount above tenant threshold)

## Edge cases

| # | Scenario | Behavior |
|---|---|---|
| 1 | Network drop mid-add | Optimistic line shows "syncing" badge; ky retries 2x; if still failing, line stays in Zustand with offline banner; replay on reconnect |
| 2 | Page reload / tab crash | Zustand persisted in localStorage; on mount check sale_id → GET /sales/{id}; if DRAFT, restore; if other status, discard local |
| 3 | Cashier B logs in where A had parked sale | GET /sales?status=PARKED&register_session_id=...; modal "Bekleyen N satış" |
| 4 | Register session not open | Block POS; modal "Kasa açılmamış" |
| 5 | Tenant blocked mid-sale | 403 TENANT_BLOCKED; modal explanation; cart preserved in localStorage |
| 6 | DRAFT abandoned (cashier walked away) | Server job: idle > 15min → ABANDONED; stock unaffected |

## Layout

```
┌─ Top bar ─────────────────────────────────────────────────────────┐
│  [Store: Beyoğlu] [Cashier: Ayşe] [Session: #4521]   [Esc: İptal]│
├──────────────────────────────────────┬───────────────────────────┤
│                                       │                            │
│  CART (60%)                           │  RIGHT PANEL (40%)         │
│                                       │                            │
│  ┌──────────────────────────────┐    │  ┌──────────────────────┐ │
│  │ Customer:                    │    │  │  CUSTOMER INFO       │ │
│  │ [F2] Walk-in (no customer)  │    │  │  (when set)          │ │
│  └──────────────────────────────┘    │  │  Name, balance,      │ │
│                                       │  │  credit limit        │ │
│  ┌─ Cart lines ──────────────────┐   │  └──────────────────────┘ │
│  │ ▶ T-shirt Black/M    × 2  ₺198│   │                            │
│  │   Jeans Blue/32      × 1  ₺450│   │  ┌──────────────────────┐ │
│  │   [↑↓ navigate, +/- qty]     │   │  │  TOTALS              │ │
│  │                              │   │  │   Kalemler:    ₺648 │ │
│  │   (scrollable; virtualized   │   │  │   Ara toplam: ₺648  │ │
│  │   for 50+ items)             │   │  │   KDV %20:    ₺100  │ │
│  └──────────────────────────────┘   │  │   İskonto:    -₺48  │ │
│                                       │  │   ─────────────────  │ │
│  ┌─ Cart-wide actions ───────────┐   │  │   TOPLAM:    ₺700   │ │
│  │ [F3] Discount  [F4] Hold sale│   │  └──────────────────────┘ │
│  └──────────────────────────────┘   │                            │
│                                       │  ┌──────────────────────┐ │
│                                       │  │  [F12] TAMAMLA       │ │
│                                       │  │      (Big button)     │ │
│                                       │  └──────────────────────┘ │
├──────────────────────────────────────┴───────────────────────────┤
│ Footer: [F1 Ara] [F2 Müşteri] [F3 İskonto] [F4 Bekleyen]         │
│         [F5 Geri Yükle] [F8 Çekmece] [F9 Tekrar Yazdır]          │
└──────────────────────────────────────────────────────────────────┘
```

### Pre-cart variant (no items, no Sale row)

- Cart area centered message: "Barkod tarayın veya F1 ile arayın"
- All totals zero
- F12 Tamamla disabled
- First successful scan/search triggers POST /sales → cart populated

## Cart totals breakdown

The right-panel TOTALS area distinguishes client-computed preview from server-authoritative values:

- **Kalemler** (Items sum): Client-computed via Dinero.js, instant
- **Ara toplam, KDV, İskonto, TOPLAM**: Server-authoritative; shimmer/skeleton during 250-400ms server response

Client/server mismatch > ₺0.01: silent toast "Toplam güncellendi" + Sentry event (per Phase 6.G observability).

## Implementation notes

- Cart lines virtualized via TanStack Virtual above 50 items
- All money values from Dinero.js; Intl.NumberFormat for display only
- F-key labels in footer localized; bindings constant
- "TAMAMLA" button intentionally large + green for touch support
- Audio cues configurable per cashier (user prefs, not tenant)
- Network status indicator in top bar: green/yellow/red dot
