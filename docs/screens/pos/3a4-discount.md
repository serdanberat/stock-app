# 3.A.4 — Discount Modal (F3)

> **Status:** Locked (Phase 3.A)
> **Trigger:** F3 from POS Main Sale

## Purpose

Apply a discount to either a specific cart line or the entire cart. Also covers "override final price" as a sibling flow with distinct permissions and authoritative semantics.

Scope decided automatically by UI focus state — no "what do you want to discount?" preamble.

## Mutual exclusivity (MVP rule)

A Sale has **at most ONE** of:
- (a) Cart-wide discount
- (b) Line-level discounts (one or many lines)

Applying one disables the other. Stacking forbidden in MVP.

### Why

VAT recomputation under stacked discounts produces rounding drift, complicates audit, and confuses future campaign rules. v1.1+ may relax with explicit stacking-priority rules.

## Scope resolution

Modal opens with derived scope:
- Line focused in cart → "Satır İndirimi"
- No focus / cart-level → "Sepet İndirimi"

User can switch via segmented control. Warning if other-scope discount exists:

> "Sepet indirimi varsa satır indirimi uygulanamaz. Önce kaldır."

## Reads

- Current Sale state (Zustand + server)
- `GET /users/me/discount-limits`
  - Returns: max_line_discount_pct, max_cart_discount_pct, requires_reason_threshold
  - Cached 5min server-side; refresh on permission change

## Writes

| Endpoint | Purpose |
|---|---|
| `PATCH /sales/{id}/items/{lineId}/discount` | Line discount |
| `PATCH /sales/{id}/discount` | Cart-wide discount |
| `DELETE /sales/{id}/items/{lineId}/discount` | Remove line discount |
| `DELETE /sales/{id}/discount` | Remove cart-wide discount |

Request body:
```json
{
  "type": "PERCENT | AMOUNT | OVERRIDE_PRICE",
  "value": "<decimal>",
  "reason_code": "PROMO | DAMAGED_ITEM | LOYALTY | PRICE_MATCH | MANUAL_GOODWILL | EMPLOYEE_DISCOUNT",
  "manager_override_token": "<jwt|null>"
}
```

Response: fully-recomputed Sale (server authoritative).

## Optimistic UI

**NO.** Discount is fraud-sensitive and server authoritative. Client shows loading 200-400ms, renders server response.

## Persistence

Immediate. NOT batched. Every discount mutation hits audit log atomically.

## Locking

None at DRAFT (single-cashier ownership). Optimistic version check on Sale.

## Keyboard flow

| Key | Action |
|---|---|
| F3 | Opens modal in derived scope |
| 1-5 | Jump to preset chips (%5, %10, %15, %20, Özel) |
| Enter | Apply (if form valid) |
| Esc | Cancel, no mutation |
| Tab | scope toggle → type tabs → presets → input → reason → manager PIN → Apply → Cancel |

## Barcode flow

Inherits 3.A.2 — scanner never suspended. Modal scan auto-closes WITHOUT applying → add-item pipeline.

## Discount types

| Type | Semantics |
|---|---|
| PERCENT | % of unit/cart price |
| AMOUNT | Fixed amount discount |
| OVERRIDE_PRICE | Manual repricing (≠ discount) |

### Override price vs discount — semantic distinction

```java
public record SaleItem(
    BigDecimal unitPriceGross,           // current effective
    BigDecimal originalUnitPriceGross,   // captured at line-add; never null
    BigDecimal unitDiscount,             // discount amount, may be 0
    DiscountType discountType,           // PERCENT | AMOUNT | null
    boolean manualPriceOverride,         // true if override flow used
    String priceSource                   // enum value
);
```

Three states:
- `unitDiscount = 0, manualPriceOverride = false` → regular sale
- `unitDiscount > 0, manualPriceOverride = false` → discount applied
- `unitDiscount = 0, manualPriceOverride = true` → repriced

Reports distinguish:
- `Total discount given` = SUM(unitDiscount × quantity) where manualPriceOverride = false
- `Total revenue lost to repricing` = SUM((originalUnitPriceGross - unitPriceGross) × quantity) where manualPriceOverride = true

## Preset chips

- %5, %10, %15, %20, Özel
- Keys 1-5 jump to preset (5=Özel triggers custom input focus)
- Mantine Chip in segmented group
- Slider NOT used (too slow for POS)

## Discount reason policy

Tenant feature flag: `requires_reason_above_pct` (default %10; range 0-30)

### Reason options (closed set)

| Code | Turkish |
|---|---|
| PROMO | Tanıtım/Promosyon |
| DAMAGED_ITEM | Hasarlı ürün |
| LOYALTY | Sadık müşteri |
| PRICE_MATCH | Rakip eşleştirme |
| MANUAL_GOODWILL | İyi niyet jesti |
| EMPLOYEE_DISCOUNT | Çalışan indirimi |

### EMPLOYEE_DISCOUNT validation

Server check: customer attached to Sale must have EMPLOYEE role. Otherwise:
- 422 with code `EMPLOYEE_DISCOUNT_REQUIRES_EMPLOYEE_CUSTOMER`

### Rules

- ≤ threshold: reason optional (dropdown shown, not required)
- > threshold: reason mandatory
- Any manager override: reason mandatory regardless
- Override price: reason ALWAYS mandatory

Free-text reasons forbidden (report cleanliness).

## Permissions

| Permission | Default role |
|---|---|
| sales.discount.apply | CASHIER (with limit) |
| sales.discount.high_value | STORE_MANAGER |
| sales.override_price | STORE_MANAGER |
| sales.discount.bypass_limit | None (always requires manager PIN) |

## Default discount limits (tenant-configurable, range 0-50)

| Role | Line % | Cart % | Override price |
|---|---|---|---|
| CASHIER | 10 | 10 | No |
| STORE_MANAGER | 30 | 30 | Yes |
| SUPER_ADMIN | unlimited | unlimited | Yes |

## Manager override (PIN-based inline)

### PIN

- 6-digit numeric
- Hashed via shared `CredentialHasher` (BCrypt cost 12)
- Per-user (`users.manager_pin_hash`)

### Lockout

Scope: `(tenant_id, register_session_id)` (NOT per-user)

- Sliding window: 5 minutes
- Threshold: 3 non-success outcomes
- Source of truth: `manager_pin_attempts` table (append-only)
- Locks any further PIN attempt in same register session regardless of attempted_manager_user_id (prevents cashier enumeration)
- Auto-reset on expiry: lockout window passes → counter resets

### Override token

JWT signed with `static_secret + server_instance_nonce`:
- JVM restart → new nonce → old tokens invalidated (server-restart safety)
- Single-use enforcement: pure Caffeine cache MVP (no DB ledger)
- Expiry: 5min
- Action-bound: token carries full `approved_action` payload

```json
{
  "jti": "...",
  "sub": "manager_user_id",
  "iat": ...,
  "exp": ... (+5min),
  "act": "discount.apply",
  "approved_action": {
    "type": "PERCENT",
    "value": "20.00",
    "scope": "LINE",
    "sale_id": "sale-uuid",
    "line_id": "line-uuid",
    "reason_code": "DAMAGED_ITEM"
  }
}
```

### Mismatch detection

Server validates exact match:

```java
if (!approved.matches(cmd)) {
    throw new ManagerOverrideMismatchException();
}
```

Mismatch → 409 + audit `discount_override_mismatch_attempted`.

### UX flow

1. Cashier types discount value
2. Modal validates client-side; if exceeds limit, shows PIN field
3. Manager comes, taps PIN
4. Apply clicked → `POST /auth/manager-override` → token
5. Discount PATCH includes token
6. Server validates + applies

**Token issued only on Apply** (not on PIN entry). Allows modal value tweaking before commit.

## Audit events

- `sale_discount_applied`
- `sale_discount_removed`
- `sale_line_discount_applied`
- `sale_line_discount_removed`
- `sale_line_price_overridden`
- `sale_line_price_override_removed`
- `discount_override_attempted`
- `discount_override_mismatch_attempted`
- `manager_pin_lockout`

Each event carries:
- actor_user_id
- sale_id, line_id (if applicable)
- discount_type, discount_value, reason_code
- had_manager_override (boolean)
- manager_override_jti (if applicable)
- previous_state (for remove events)

## Speed budget

| Action | p95 target |
|---|---|
| Open modal | < 80ms |
| Preset → apply | < 400ms |
| Custom + apply | < 500ms |
| Manager PIN verification | < 600ms |

## Edge cases

| # | Scenario | Behavior |
|---|---|---|
| 1 | Cart discount + try line discount | UI disabled, hint: "Önce sepet indirimini kaldır" |
| 2 | Line discounts + try cart discount | Apply blocked: "N satır indirimi aktif; tümünü kaldır" |
| 3 | Manager PIN wrong 3 times | Register-session lockout 5min; audit `manager_pin_lockout` |
| 4 | Manager not assigned to store | PIN match succeeds, authorization fails: "Bu mağazada yetkili değil"; audit `cross_store_override_attempted` |
| 5 | Discount > 100% (typo) | Client + server validation reject |
| 6 | Discount amount > line gross | Server caps at gross; toast "Maksimum uygulandı: ₺X" |
| 7 | Override price > current (markup) | Allowed with warning "Fiyat artırılıyor"; audit captures direction |
| 8 | Sale past DRAFT | 409 "Sale not editable"; modal closes |
| 9 | Concurrent edit (two tabs) | Optimistic version mismatch 409; UI refreshes, hint "Satış güncellendi" |

## Layout

```
┌─ Modal (centered, ~50% screen) ─────────────────────────────────┐
│                                                                   │
│   Satır İndirimi   /   Sepet İndirimi                             │
│   ─────────────       ───────────────                             │
│   (T-shirt Black/M × 2)                                           │
│   Mevcut: ₺198    Yeni Toplam: ₺178 (preview)                    │
│                                                                   │
│   ┌─ Tip seç ──────────────────────────────────┐                 │
│   │ [ Yüzde ]  [ Tutar ]  [ Fiyat Sabitle* ]    │                 │
│   └────────────────────────────────────────────┘                 │
│   * sadece yetkili kullanıcıda görünür                            │
│                                                                   │
│   Hızlı seç:                                                      │
│   [%5]  [%10]  [%15]  [%20]  [Özel]                              │
│   (1-5 tuşları)                                                   │
│                                                                   │
│   İndirim:  [10] %     (Yüzde tipi seçiliyse)                    │
│   İndirim:  [₺_____]   (Tutar tipi seçiliyse)                    │
│   Yeni Fiyat: [₺_____] (Fiyat sabitle tipi seçiliyse)            │
│                                                                   │
│   Sebep:                                                          │
│   [ PROMO ▾ ]   (zorunlu/opsiyonel threshold'a göre)              │
│                                                                   │
│   ┌─ Yönetici onayı (limit aşılırsa görünür) ──────────────────┐│
│   │   Yetkiniz: max %10                                          ││
│   │   Talep: %20 — yönetici onayı gerekli                       ││
│   │   Yönetici PIN: [____]                                       ││
│   └──────────────────────────────────────────────────────────────┘│
│                                                                   │
│   [İptal (Esc)]              [Uygula (Enter)]                     │
│                                                                   │
└───────────────────────────────────────────────────────────────────┘
```

## Visual distinction in cart

```
T-shirt Black/M    ₺99 → ₺89  [-%10 PROMO]      ← discount style (sarı badge)
Kot Pantolon       ₺450 → ₺400  [SABİTLENMİŞ]    ← override style (kırmızı badge)
```

## Implementation notes

- "Yeni Toplam" preview: client Dinero (gray text → black on server confirm)
- Preset chips: Mantine Chip segmented group
- Reason dropdown: Mantine Select; disabled if not required
- Manager PIN: PasswordInput, `inputMode="numeric"`, autoComplete off
- "Fiyat Sabitle" tab: hidden via permission check (not just disabled)
- Apply disabled until: valid input + reason if required + PIN if required
- Success toast: "İndirim uygulandı" or "Yönetici onayıyla uygulandı"
