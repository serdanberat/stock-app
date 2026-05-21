# 3.C.5 — Stock Adjustment

> **Status:** Locked (Phase 3.C)
> **Routes:**
> - `/inventory/adjustments` — List view (audit history)
> - `/inventory/adjustments/new` — Create
> - `/inventory/adjustments/new?prefill_variant={id}&prefill_store={id}` — Deeplink from 3.C.1 or 3.C.2
> - `/inventory/adjustments/{id}` — Read-only detail (no edit)

## Purpose

Direct stock correction by manager. Heaviest audit surface in Inventory. Used when:
- Damage discovered (broken merchandise)
- Loss (theft, missing, disappeared — wording deliberately ambiguous-tolerant)
- Internal use (display, employee sample)
- Gift / sample (marketing giveaway)
- Expiration (cosmetics, end-of-season)
- Other (free-text reason mandatory)

**NOT the path for**: sales (POS), purchases (3.D), transfers (3.C.3), or count corrections (3.C.4). Each has its own movement type.

## Single-shot semantics

Unlike Transfer (multi-state) and Count (lifecycle), Adjustment is one-shot: create + commit atomically. **No DRAFT**, no state machine.

Once created, an Adjustment is immutable. Mistake correction = create reverse adjustment with reason OTHER + reference to original.

Rationale: adjustments are operational corrections and audit-heavy. Draft adjustments would create forgotten draft, stale intent, fraud ambiguity, and "kim neyi commit edecekti?" confusion.

## Aggregate ownership (explicit)

- **Writes** Adjustment aggregate (single-shot, no state machine)
- **Writes** stock_movements indirectly via creation:
  - `ADJUSTMENT_IN` movement (positive quantity correction)
  - `ADJUSTMENT_OUT` movement (negative quantity correction)
- **Reads** stock_balances for current quantity reference

## Reads

- `POST /inventory/adjustments/search` — Body: `{ store_id?, variant_id?, reason_code?, date_from/to?, actor_user_id?, page, page_size }`
- `GET /inventory/adjustments/{id}`
- `GET /inventory/stock-balances/{variant_id}/{store_id}` — For current quantity display during create

## Writes

- `POST /inventory/adjustments`
  - X-Idempotency-Key required
  - Body:
    ```
    {
      store_id,
      lines: [
        {
          variant_id,
          quantity_delta,           // signed: +5 = add, -3 = remove
          reason_code,
          free_text_reason?         // required if reason_code = OTHER
        }
      ],
      note?                         // overall session note
    }
    ```
  - Atomically: for each line, ADJUSTMENT_IN (positive) or ADJUSTMENT_OUT (negative) movement; stock_balances FOR UPDATE apply delta; validate `allow_negative_stock`; Adjustment.id correlation across generated movements

## Reason codes (closed set)

| Code | Meaning |
|---|---|
| `DAMAGE` | Hasar (kırık, sökülmüş, leke) |
| `LOSS` | Kayıp (theft, lost in store — ambiguous-tolerant) |
| `COUNT_CORRECTION` | Sayım sonucu düzeltme (auto-applied from 3.C.4; NOT selectable manually) |
| `SUPPLIER_RETURN` | Tedarikçiye iade (preferred path: 3.D Financial flows; fallback for ad-hoc) |
| `EXPIRED` | Süre dolması (cosmetics, seasonal) |
| `INTERNAL_USE` | Mağaza kullanımı (display, sample) |
| `GIFT` | Hediye/numune (marketing) |
| `TRANSFER_CANCELLED` | Transfer iptali sonrası geri ekleme (auto-applied from 3.C.3; NOT selectable manually) |
| `OTHER` | Diğer (free_text_reason mandatory; future analytics has subreason note placeholder) |

## Optimistic UI

NO. Adjustments are fraud-sensitive. Wait for server confirmation.

## Locking

Pessimistic FOR UPDATE on stock_balances rows during commit (canonical variant_id ASC).

## Idempotency

X-Idempotency-Key required on create.

## Keyboard flow (CREATE form)

| Key | Action |
|---|---|
| Tab | store → line search → add → quantity → reason → save |
| ⌕ | Barcode scanner adds line (or focuses existing) |
| `Ctrl+S` | Save |
| `Esc` | Discard with confirm if dirty |

## Barcode flow

Scanner ACTIVE in create form.

Scan resolves barcode → variant_id:
- If line exists for variant: focus, prepare to edit
- If line doesn't exist: add new line with **quantity_delta = -1** (assumption: most adjustments are losses) and **immediate negative styling** (red tint + "Çıkış" badge) — prevents accidental positive save

User can override sign and quantity.

## Speed budget

| Action | p95 target |
|---|---|
| Save (10 lines) | < 800ms |
| List query | < 400ms |

## Permissions

| Permission | Default |
|---|---|
| `inventory.adjustments.view` | STORE_MANAGER+, AUDITOR+ |
| `inventory.adjustments.create` | STORE_MANAGER+ |
| `inventory.adjustments.create_large` | STORE_MANAGER+ with second confirm if total quantity > tenant threshold (default 50) |

CASHIER and STOCK_CLERK: no access. Adjustments are manager-level.

## Large adjustment safeguard

Tenant setting: `adjustment_large_threshold` (default 50 units)

If `SUM(|quantity_delta|) > threshold`:
- Save button requires second confirmation modal:
  ```
  "Bu büyük bir düzeltme: 67 adet toplam. Sebepleri kontrol et."
  [İptal]  [Onaylıyorum, Devam Et]
  ```

Cognitive friction for large changes. No manager-override token needed (manager IS already the actor).

## Duplicate line merge

Same variant added twice in lines:
- If same reason: lines merged; quantity_delta summed
- If different reasons: server rejects with 422 "Aynı varyant için farklı sebep verilemez. Tek satıra al."

Rationale: tek operational intent olmalı.

## Edge cases

| # | Scenario | Behavior |
|---|---|---|
| 1 | Adjustment would push balance negative | If tenant `allow_negative_stock=false`: 422 rejection; UI inline error on line; show current balance. If `true`: warning toast on save, proceed |
| 2 | Same variant added twice in lines | Same reason: merge; different reasons: 422 |
| 3 | Network drop during save | Idempotency-Key retries safely; no partial commit (atomic TX) |
| 4 | Variant deactivated | Allowed (cleanup of deactivated variant); warning "Bu varyant pasif. Düzeltme uygulanabilir." |
| 5 | Mistake: wrong reason | Cannot edit (single-shot); workflow: create reverse adjustment with reason OTHER + note referencing original adjustment ID; audit preserves both |
| 6 | Concurrent adjustments on same variant | Pessimistic FOR UPDATE serializes; both succeed; ledger reflects both |

## Layout — LIST view

```
┌─ Inventory Shell > Düzeltme ──────────────────────────────────────┐
│                                                                    │
│  ⌕ [Search by note, SKU...]      [+ Yeni Düzeltme]                │
│  Mağaza: [Beyoğlu ▾]   Sebep: [Tümü ▾]   Tarih: [Son 30g ▾]      │
│                                                                    │
│  ┌─ Adjustments ─────────────────────────────────────────────┐   │
│  │ Tarih       │ Mağaza  │ Kalem │Aktör   │Toplam│Sebepler  │ │   │
│  ├─────────────┼─────────┼───────┼────────┼──────┼──────────┤│   │
│  │16/05 14:00  │Beyoğlu  │  3    │Mehmet  │ -8   │DAMAGE,LOSS│   │
│  │16/05 11:30  │Kadıköy  │  1    │Ayşe    │ -2   │EXPIRED   │ │   │
│  │15/05 16:00  │Beyoğlu  │  5    │Mehmet  │+12⚠  │OTHER     │ │   │
│  │             │         │       │        │      │"return..."│   │
│  └────────────────────────────────────────────────────────────┘   │
│  ⚠ = büyük düzeltme (>50 adet)                                     │
│                                                                    │
└────────────────────────────────────────────────────────────────────┘
```

## Layout — CREATE form

```
┌─ Yeni Stok Düzeltmesi ────────────────────────────────────────────┐
│                                                                    │
│  Mağaza: [Beyoğlu ▾]                                              │
│  Not: [Pazartesi sabahı bulunan hasarlar]                          │
│                                                                    │
│  ⌕ [SKU veya barkod tara]                                          │
│                                                                    │
│  ┌─ Lines ────────────────────────────────────────────────────┐   │
│  │ Varyant       │Mevcut │ Δ Miktar │ Sebep         │ Not    │   │
│  ├───────────────┼───────┼──────────┼───────────────┼────────┤   │
│  │T-100-BLK-S    │  5    │  [-2] 🔴 │ [DAMAGE ▾]   │ [Sol  ][Sil]│
│  │T-100-WHT-M    │  3    │  [-1] 🔴 │ [LOSS ▾]     │ [Dis ][Sil]│
│  │J-450-BLU-32   │  12   │  [+1] 🟢 │ [OTHER ▾]    │ [Bulundu][Sil]│
│  │               │       │          │ Açıklama:     │              │
│  │               │       │          │ [stok odasında]│              │
│  └────────────────────────────────────────────────────────────┘   │
│                                                                    │
│  Toplam delta: -2 adet  (mutlak toplam: 4)                         │
│                                                                    │
│  [Esc İptal]                                  [Kaydet (Ctrl+S)]   │
│                                                                    │
└────────────────────────────────────────────────────────────────────┘
```

Visual cues:
- Negative quantity_delta: red tint + 🔴 indicator immediately on entry
- Positive quantity_delta: green tint + 🟢 indicator
- OTHER reason: explanation textarea expands inline

## Audit events

- `adjustment_created` (with line details + actor + reasons + correlation_id)
- `adjustment_large_confirmed` (when over threshold)
- `adjustment_negative_stock_warned` (when balance went negative)

## Implementation notes

- Single-shot create form; no DRAFT save
- Reason dropdown excludes COUNT_CORRECTION and TRANSFER_CANCELLED (system-generated only)
- `free_text_reason` field appears only when OTHER selected
- Large adjustment threshold from tenant settings
- Sign of `quantity_delta` determines movement_type (ADJUSTMENT_IN vs ADJUSTMENT_OUT)
- Scanner default sign = -1 with immediate negative styling (prevents accidental + save)
- Detail view read-only (no edit endpoint exists)
- Reverse adjustment workflow documented in user-facing help (not UI)
- `correlation_id = adjustment.id` shared across all movements from this adjustment session
- Future: subreason note placeholder for analytics on LOSS sub-classification
