# 3.E.4 — Tenant Feature Flags

> **Status:** Locked (Phase 3.E)
> **Route:** `/admin/settings`

## Purpose

Manage tenant-level configuration. Categorized form; two tiers (operational vs dangerous).

## Aggregate ownership (explicit)

- **Writes** `Tenant.settings` (JSONB)

## Two-tier categorization

### OPERATIONAL (regular configuration)

| Key | Default | Purpose |
|---|---|---|
| `return_window_days` | 30 | Days for reference-based return validity |
| `requires_reason_above_pct` | 10 | Discount % threshold above which reason required |
| `max_line_discount_pct_default` | 30 | Cashier max line discount |
| `max_cart_discount_pct_default` | 30 | Cashier max cart discount |
| `adjustment_large_threshold` | 50 | Adjustment unit count requiring second confirm |
| `low_stock_default_threshold` | 5 | Low stock highlight threshold |
| `manager_pin_lockout_minutes` | 5 | Lockout after 3 failed PIN attempts |
| `cash_variance_tolerance` | 5 | TL tolerance for cash close without reason |
| `cash_variance_large_threshold` | 100 | Requires manager PIN at close |
| `currency_code` | TRY | Locked TRY MVP |
| `decimal_places` | 2 | Locked 2 MVP |

### DANGEROUS (require extra confirmation + warning)

| Key | Default | Effect |
|---|---|---|
| `allow_negative_stock` | false | Allow sales/transfers/adjustments to push balance below zero |
| `allow_force_create_duplicate_customer` | false | Bypass phone duplicate guard (v1.1+) |
| `allow_below_cost_pricing` | true | Sale price below WAC warning UX only |

## Dangerous flag UX

```
┌─ Negatif Stoğa İzin Ver ───────────────────────────────────────────┐
│                                                                    │
│  Şu an: KAPALI                                                     │
│  Yeni:  [Açık ▾]                                                   │
│                                                                    │
│  ⚠ Tehlikeli ayar                                                  │
│                                                                    │
│  Negatif stok aktif edildiğinde:                                   │
│  - Stok kalmadığında bile satış yapılabilir                        │
│  - Sayım doğruluğu zorlaşır                                        │
│  - Kâr hesabı bozulabilir                                          │
│  - WAC stabilizasyonu kaybolur                                     │
│                                                                    │
│  Onaylamak için altına yazın: "negatif stok onaylıyorum"          │
│  [______________________________________________]                  │
│                                                                    │
│  [İptal]                              [Onayla ve Uygula]           │
│                                                                    │
└────────────────────────────────────────────────────────────────────┘
```

**Confirmation phrase requirement**: explicit typed acknowledgment for dangerous flags. Prevents accidental click.

## Optimistic UI

- Operational flags: yes (debounced commit)
- Dangerous flags: NO (modal confirm flow)

## Permissions

| Permission | Default |
|---|---|
| `admin.settings.view` | STORE_MANAGER+, SUPER_ADMIN |
| `admin.settings.edit_operational` | SUPER_ADMIN; STORE_MANAGER (subset) |
| `admin.settings.edit_dangerous` | SUPER_ADMIN only |

## Layout

```
┌─ Admin Shell > Ayarlar ───────────────────────────────────────────┐
│                                                                    │
│  [POS] [Envanter] [Finans] [Güvenlik] [Tehlikeli]                 │
│                                                                    │
│  ┌─ POS Ayarları ────────────────────────────────────────────┐   │
│  │ İade süresi (gün):              [30]                       │   │
│  │ İskonto sebebi zorunlu eşik:   [%10]                       │   │
│  │ Kasiyer max satır indirimi:    [%10]                       │   │
│  │ Kasiyer max sepet indirimi:    [%10]                       │   │
│  │ Manager max satır indirimi:    [%30]                       │   │
│  │ Manager max sepet indirimi:    [%30]                       │   │
│  │ Manager PIN kilit süresi (dk): [5]                         │   │
│  └────────────────────────────────────────────────────────────┘   │
│                                                                    │
│  ┌─ Envanter Ayarları ───────────────────────────────────────┐   │
│  │ Düşük stok eşiği:              [5]                         │   │
│  │ Büyük düzeltme eşiği:          [50 adet]                   │   │
│  └────────────────────────────────────────────────────────────┘   │
│                                                                    │
│  ┌─ Finans Ayarları ─────────────────────────────────────────┐   │
│  │ Kasa varyans toleransı:        [₺ 5]                       │   │
│  │ Büyük varyans eşiği:           [₺ 100]                     │   │
│  └────────────────────────────────────────────────────────────┘   │
│                                                                    │
│  ┌─ ⚠ Tehlikeli Ayarlar (SUPER_ADMIN only) ──────────────────┐   │
│  │ Negatif stoğa izin ver:        [KAPALI]                    │   │
│  │ Maliyetin altında satış:       [AÇIK] (uyarı sadece)       │   │
│  └────────────────────────────────────────────────────────────┘   │
│                                                                    │
└────────────────────────────────────────────────────────────────────┘
```

## Audit events

- `tenant_setting_changed` (with key, old_value, new_value, actor)
- `dangerous_flag_toggled` (separate event for SIEM filtering)

## Implementation notes

- JSONB schema-validated server-side; Bean Validation
- Each field has tooltip with description and effect
- Locale/currency locked MVP (TRY only)
- Dangerous tab visually distinct (red border, warning icon)
- Changes effective immediately for new operations; in-flight operations use captured config at start (see Snapshot policy below)
- Dangerous flag toggle requires typed phrase confirmation per flag (i18n key per flag)

## Snapshot policy — operation-start config capture

Mid-operation policy changes must not retroactively invalidate in-flight work. Open POS sale with %30 discount mid-flow must not break when manager tightens cart_discount to %10 in another tab. Snapshot at operation start guarantees determinism.

**Explicit snapshot binding**:

| Setting | When captured | Where snapshotted |
|---|---|---|
| `requires_reason_above_pct` | Sale aggregate creation (open DRAFT) | `sale.discount_threshold_snapshot` |
| `max_cart_discount_pct_default` | Sale DRAFT creation | `sale.cart_discount_limit_snapshot` |
| `max_line_discount_pct_default` | Sale DRAFT creation | `sale.line_discount_limit_snapshot` |
| `return_window_days` | Return.initiate() | `return.window_snapshot` |
| `adjustment_large_threshold` | Adjustment.create() | `adjustment.large_threshold_snapshot` |
| `cash_variance_tolerance` | CashRegisterSession.open() | `cash_register_session.variance_tolerance_snapshot` |
| `cash_variance_large_threshold` | CashRegisterSession.open() | `cash_register_session.variance_large_threshold_snapshot` |
| `manager_pin_lockout_minutes` | PIN attempt start (per session) | derived from session.open snapshot |

**Pricing already snapshot-frozen per ADR-018**: line.unit_price_gross is frozen at add-to-cart, not affected by mid-sale price list changes. This snapshot policy adds **policy snapshotting** alongside the existing price snapshotting.

**Schema impact**: snapshot columns added to `sales`, `returns`, `adjustments`, `cash_register_sessions` tables — see migration 023 (Phase 3.F patch).
