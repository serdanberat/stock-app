# 3.C.4 — Stock Count Session

> **Status:** Locked (Phase 3.C)
> **Routes:**
> - `/inventory/counts` — List view
> - `/inventory/counts/new` — Create new session
> - `/inventory/counts/{id}` — Detail view (state-dependent UI)

## Purpose

Manual physical inventory count. Compare expected (system) quantities against counted (physical) quantities. Trigger adjustments for discrepancies.

**MVP scope**: category-based count + spot-check (single variant or small set). Full-store count deferred to v1.1+ (requires freeze-window planning).

## Aggregate ownership (explicit)

- **Writes** CountSession aggregate (state machine + lines)
- **Reads** stock_balances (snapshot at session start via REPEATABLE READ; no FOR UPDATE)
- **Writes** stock_movements indirectly via finalization:
  - `COUNT_CORRECTION` movements (signed +/- per discrepancy line)
- **Reads** ProductVariant for display_name (Catalog ctx)

## State machine

```
    DRAFT
      │ start()
      ↓
    IN_PROGRESS  (snapshot taken; counting underway)
      │ finalize()
      ↓
    FINALIZED
    (terminal; adjustments applied)
```

Cancellation from DRAFT or IN_PROGRESS: → CANCELLED (no stock movement).

## Rolling count model (CRITICAL)

Count session DOES NOT freeze inventory operations.

During IN_PROGRESS:
- Sales continue (SALE_OUT movements happen)
- Transfers continue
- Purchases continue
- Adjustments continue

Snapshot is captured at `start()`:
```
snapshot_qty[variant_id] = stock_balances.quantity_on_hand at T0
```

**Snapshot isolation**: REPEATABLE READ MVCC snapshot — NOT FOR UPDATE. Inventory operations are not blocked during count. (This is an explicit correction from earlier draft: rolling count requires non-blocking snapshot.)

Movement tracking during session:
```
session_movements[variant_id] = SUM(movements where
    variant_id in scope AND
    occurred_at >= session.started_at AND
    occurred_at < session.finalized_at)
```

Expected at finalization:
```
expected_qty = snapshot_qty + session_movements
```

Variance:
```
variance = counted_qty - expected_qty
```

If `variance != 0`: `COUNT_CORRECTION` movement with `quantity = variance`.

UI displays variance breakdown so manager understands "neden ben 5 saydım ama sistem 6 diyor": "Sayım başladıktan sonra 2 satış oldu, 1 transfer geldi. Sistem beklenen ayarladı: 5."

## Allowed mutations per state

| State | Allowed |
|---|---|
| DRAFT | add/remove variants in scope; change store_id; change scope (category, variants); delete (no audit); start |
| IN_PROGRESS | ✗ scope mutations LOCKED; enter/update counted_quantity per line; add notes per line; finalize; cancel |
| FINALIZED, CANCELLED | Terminal. No mutations. |

## Reads

- `GET /inventory/counts/{id}`
- `POST /inventory/counts/search`
- `GET /inventory/counts/{id}/movements-during-session` — Returns movements that happened on scoped variants between `started_at` and now/finalized_at. Used for variance explanation.

## Writes

| Endpoint | Purpose |
|---|---|
| `POST /inventory/counts` | Body: `{ store_id, scope: { type: 'CATEGORY' \| 'VARIANTS', category_id? OR variant_ids[] }, note? }` — Creates DRAFT |
| `PATCH /inventory/counts/{id}` | Body: `{ scope?, note? }` — Only DRAFT |
| `POST /inventory/counts/{id}/start` | Atomically: status=IN_PROGRESS; capture snapshot_quantity per variant in scope (REPEATABLE READ MVCC); started_at=now() |
| `PATCH /inventory/counts/{id}/lines/{lineId}` | Body: `{ counted_quantity, note? }` — Only IN_PROGRESS |
| `POST /inventory/counts/{id}/finalize` | Idempotency-Key required. Atomically: for each line with counted_quantity set, compute expected = snapshot + session_movements; variance = counted - expected; if variance != 0: COUNT_CORRECTION movement with reason COUNT_CORRECTION and `correlation_id = count_session.id`. Skipped lines (no counted_quantity) get no adjustment. status=FINALIZED |
| `POST /inventory/counts/{id}/cancel` | Body: `{ reason }`. No stock movement; just audit |

## Optimistic UI

- Line counted_quantity update: yes (with debounce 400ms commit)
- State transitions: NO
- Finalize: NO (server validates + atomic)

## Locking

Pessimistic FOR UPDATE on stock_balances during finalize only (canonical order by variant_id ASC).

Snapshot capture at `start()` uses **REPEATABLE READ MVCC** (NOT FOR UPDATE) — inventory operations remain unblocked during the session. This is core to rolling count model.

## Idempotency

`start`, `finalize`, `cancel`: X-Idempotency-Key required.

## Keyboard flow (LIST view)

| Key | Action |
|---|---|
| `/` or `Ctrl+K` | Focus search |
| `Ctrl+N` | New count session (DRAFT) |
| `Enter` | Open detail |

## Keyboard flow (DRAFT scope edit)

| Key | Action |
|---|---|
| Tab | store → scope type → category/variant picker → Save |
| `Ctrl+S` | Save DRAFT |
| `Ctrl+Enter` | Save and start counting |

## Keyboard flow (IN_PROGRESS counting)

| Key | Action |
|---|---|
| ⌕ Scanner | Auto-focus scan input |
| `↓ / ↑` | Row focus |
| `Enter` | Edit focused line counted_quantity inline |
| Tab | From counted_quantity to note field |
| `Esc` | Cancel inline edit |
| `Ctrl+F` | Finalize (with confirm modal showing variance summary) |

## Barcode flow (IN_PROGRESS)

Scanner is the primary count interface. Stock clerk walks shelves with handheld scanner.

Scan behavior:
- Resolve barcode → variant_id
- If variant in session scope: increment counted_quantity by 1
- If variant NOT in scope: warning toast "Bu varyant sayım kapsamında değil. Yine de eklemek için sayım kapsamını genişletmen gerekli (Cancel + recreate)."
- Visual feedback: row highlights briefly, counted_quantity increments with animation

Bulk entry mode (alternative to scanning): clerk can enter quantity directly per row (for boxes of 12, etc.). Mantine NumberInput, Enter commits.

## Speed budget

| Action | p95 target |
|---|---|
| Scan-to-increment | < 100ms (local optimistic) |
| Line commit (debounced) | < 400ms |
| Finalize (50 lines) | < 2s |
| Variance computation per line at finalize | server-side |

## Permissions

| Permission | Default |
|---|---|
| `inventory.counts.view` | STORE_MANAGER+, STOCK_CLERK |
| `inventory.counts.create` | STORE_MANAGER+, STOCK_CLERK |
| `inventory.counts.count` | STOCK_CLERK+ (data entry) |
| `inventory.counts.finalize` | STORE_MANAGER+ (creates adjustments) |
| `inventory.counts.cancel` | STORE_MANAGER+ |

Note: STOCK_CLERK can do data entry but cannot finalize. Manager reviews variance before adjustments commit. Small boutique can grant both roles to same user via multi-role.

## Variance disclosure (CRITICAL UX)

### Aggressive completeness warning

If lines without `counted_quantity` exist at finalize:

```
⚠ 5 varyant henüz sayılmadı.
Bunlar için stok düzeltmesi yapılmayacak.
```

Manager must explicitly acknowledge before finalize proceeds.

### Variance modal

Finalize confirm modal shows variance breakdown:

```
┌─ Sayımı Tamamla ──────────────────────────────────────────────┐
│                                                                  │
│  Sayım başladıktan sonra 5 stok hareketi oldu.                  │
│  Sistem beklenen miktarı buna göre güncelledi.                  │
│                                                                  │
│  Variance Summary:                                               │
│  ┌────────────────────────────────────────────────────────┐   │
│  │ Varyant       │Snapshot│Hareket│Beklenen│Sayılan│Fark│  │   │
│  ├───────────────┼────────┼───────┼────────┼───────┼────┤  │   │
│  │ T-100-BLK-S   │   8    │  -2   │   6    │   6   │ 0  │  │   │
│  │ T-100-BLK-M   │   5    │  -1   │   4    │   3   │-1 ❗│  │   │
│  │ T-100-WHT-S   │   3    │  +5   │   8    │   8   │ 0  │  │   │
│  │ J-450-BLU-32  │  12    │   0   │  12    │  11   │-1 ❗│  │   │
│  └────────────────────────────────────────────────────────┘   │
│                                                                  │
│  Net variance:  -2 adet                                          │
│  Affected variants: 2 / 4                                        │
│  Skipped (sayılmadı): 0                                          │
│                                                                  │
│  Adjustments to be created:                                      │
│  - T-100-BLK-M: COUNT_CORRECTION -1                              │
│  - J-450-BLU-32: COUNT_CORRECTION -1                             │
│                                                                  │
│  [İptal]                            [Onayla ve Tamamla]          │
│                                                                  │
└──────────────────────────────────────────────────────────────┘
```

### Line-level tooltip

Hover on variance ⚠ icon shows movements that affected this variant during the session:

```
ℹ Bu varyantta sayım sırasında:
   - 2 satış
   - 1 transfer
```

Lightweight; no inline badge clutter; debug value preserved.

## Audit events

- `count_session_created`
- `count_session_started` (with snapshot per variant)
- `count_session_line_counted`
- `count_session_finalized` (with variance summary)
- `count_session_cancelled`
- `count_correction_applied` (per discrepancy; correlation_id = session.id)

## Edge cases

| # | Scenario | Behavior |
|---|---|---|
| 1 | Session left open for days | No auto-expiry; manager responsibility; list view shows "started X days ago" with warning if > 7 days |
| 2 | Variant not in scope but found physically | Cannot add to current session (scope locked); warning directs user: cancel + recreate, or separate adjustment via 3.C.5 |
| 3 | Variant scoped but never scanned/entered | Skipped at finalize (no COUNT_CORRECTION); aggressive warning before finalize "5 varyant henüz sayılmadı; bunlar için düzeltme yapılmayacak" |
| 4 | Counted = 0 on variant scoped | Treated as "physically zero" with variance vs expected; if expected > 0: COUNT_CORRECTION -expected (full loss); zero is valid count |
| 5 | Negative counted_quantity | Rejected (422); client NumberInput min=0 |
| 6 | Concurrent finalize attempt | Idempotency-Key + pessimistic lock; first wins; second returns same response |
| 7 | Mid-finalize stock changes (race window) | Atomic TX; movements created during finalize TX excluded (occurred_at > start of TX); race window <1s acceptable |
| 8 | Variant deactivated mid-session | Session keeps variant (snapshot captured); count proceeds; finalize applies COUNT_CORRECTION on deactivated variant (historical correction valid) |

## Layout — LIST view

```
┌─ Inventory Shell > Sayım ─────────────────────────────────────────┐
│                                                                    │
│  ⌕ [Search by session ID or note...]      [+ Yeni Sayım]          │
│  Durum: [Tümü ▾]   Mağaza: [Beyoğlu ▾]                            │
│                                                                    │
│  ┌─ Count sessions ──────────────────────────────────────────┐   │
│  │ No    │Durum     │Mağaza │Kapsam     │Varyant│Variance│Tar│ │   │
│  ├───────┼──────────┼───────┼───────────┼───────┼────────┼───┤│   │
│  │ C-042 │IN_PROG.  │Beyoğlu│T-shirt    │ 24    │ —      │Bug││   │
│  │ C-041 │FINALIZED │Beyoğlu│Spot       │  1    │-1      │Bug││   │
│  │ C-040 │FINALIZED │Kadıköy│Jean       │ 18    │-3 ❗   │Dün││   │
│  │ C-039 │CANCELLED │Beyoğlu│T-shirt    │ 24    │—       │15/││   │
│  └────────────────────────────────────────────────────────────┘   │
│                                                                    │
└────────────────────────────────────────────────────────────────────┘
```

## Layout — DRAFT setup

```
┌─ Yeni Sayım Oturumu ──────────────────────────────────────────────┐
│                                                                    │
│  Mağaza: [Beyoğlu ▾]                                              │
│  Kapsam:                                                           │
│  ◯  Kategori bazlı   [Kategori seç: T-shirt ▾]                    │
│  ◯  Tek varyant      [Variant ara/tara]                            │
│  ◉  Belirli varyantlar  [+ Variant Ekle]                          │
│       T-100-BLK-S, T-100-BLK-M, J-450-BLU-32                       │
│                                                                    │
│  Not: [İlk hafta inventory check]                                  │
│                                                                    │
│  [Esc İptal]                            [Başlat ve Say (Ctrl+S)] │
│                                                                    │
└────────────────────────────────────────────────────────────────────┘
```

## Layout — IN_PROGRESS counting

```
┌─ Sayım #C-042 / Sayımda ──────────────────────────────────────────┐
│                                                                    │
│  Başlama: 14:00  Süre: 23 dk                                       │
│  ⓘ Sayım başladıktan sonra 2 satış oldu. Sistem beklenen ayarlı. │
│                                                                    │
│  ⌕ [Barkod tara → otomatik artır]                                  │
│                                                                    │
│  ┌─ Variants to count ───────────────────────────────────────┐    │
│  │ Varyant       │ Snapshot│ Hareket │ Sayılan       │      │    │
│  ├───────────────┼─────────┼─────────┼───────────────┼──────┤    │
│  │T-100-BLK-S    │   8     │  -2     │ [6]      ✓    │ Not? │    │
│  │T-100-BLK-M    │   5     │  -1     │ [3]      ⚠ ℹ │ Not? │    │
│  │T-100-WHT-S    │   3     │  +5     │ [_]   sayılmadı│ Not?│    │
│  │J-450-BLU-32   │  12     │   0     │ [_]   sayılmadı│ Not?│    │
│  └────────────────────────────────────────────────────────────┘    │
│                                                                    │
│  ✓ = beklenen = sayılan       ⚠ = variance                         │
│  ℹ hover: line-level movement breakdown                            │
│  sayılmadı = henüz girilmemiş                                       │
│                                                                    │
│  [İptal Et]            [Tamamla (Ctrl+F)]                          │
│                                                                    │
└────────────────────────────────────────────────────────────────────┘
```

## Implementation notes

- Session-movements query computed on demand for variance display; refetched on row enter and on finalize confirm
- Inline edit via Mantine NumberInput in cell
- Note field expands as Mantine Textarea in row
- Scanner integration: auto-increment by 1 with toast feedback
- Finalize transaction includes snapshot + session_movements + counted_quantities; computes variance per line server-side
- COUNT_CORRECTION movements carry `correlation_id = count_session.id`
- Movement-during-session disclosure prevents "neden sistem yanlış?" questions from stock_clerk
- Spot-check (single variant): same flow with VARIANTS scope, 1 entry
- Subreason note placeholder for future analytics (free-text already supported)
