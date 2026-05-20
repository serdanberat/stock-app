# 3.A.3 — Customer Select Modal (F2)

> **Status:** Locked (Phase 3.A)
> **Trigger:** F2 from POS Main Sale

## Purpose

Attach a Party (customer-role) to the active Sale. Drives:
- Customer credit/debt account postings (non-cash payment)
- Customer history (sale visible in profile)
- Customer-specific pricing (v1.1+ tier)
- Loyalty points (v1.1+)

Most boutique sales are walk-in (no customer). Customer attachment essential when: credit sale, exchange, large purchase, returning customer asks for record.

## Reads

- `POST /parties/search`
  - Body: `{ role: 'CUSTOMER', q: text, limit: 20 }`
  - Search by: phone (last-7 suffix priority), name, email, tax_id
  - Returns: id, name, phone (masked), account_balance, credit_limit, status
- `GET /parties/{id}/account-summary` on highlight
  - Lightweight; balance + limit warning only (not full aging)

## Writes (on selection)

- `PATCH /sales/{id}/customer`
  - Body: `{ party_id }`
  - Server validates: party.role contains CUSTOMER, status=ACTIVE, not BLOCKED

## Optimistic UI

Yes on selection — customer panel updates immediately. Rollback shows toast if rejected.

## Locking

None on Sale.customer_id update.

## Draft autosave

Customer attachment persisted immediately (not batched).

## Keyboard flow

- On open: focus → search input
- Type query → debounced 250ms → search
- ↓/↑: Move highlight
- Enter: Select highlighted
- Tab: search → results → quick-create button → close
- Esc: Close modal without changes
- F2 again while open: no-op

## Barcode flow

Scanner never suspended (inherits from 3.A.2). Scan while modal open → modal auto-closes → barcode → add-item pipeline.

**Loyalty card barcode**: NOT supported MVP. Card scan = treated as product barcode (likely unknown → toast). MVP customer attach is keyboard-only.

## Phone search strategy

- Match on last-7 digits of normalized E.164
- Example: user types `1234567` → matches `+905321234567`
- Exact-suffix match (not anywhere-in-number)
- Backend normalization at insert/update time (application-layer via `PartyService`)

## Phone display masking

Default format: `0532 *** 1234` (middle digits hidden)

### Permission-gated unmask

Permission: `parties.view_full_phone`

| Role | Default |
|---|---|
| SUPER_ADMIN | ✓ |
| STORE_MANAGER | ✓ |
| CASHIER | ✗ (masked) |
| STOCK_CLERK | ✗ |
| ACCOUNTANT | ✓ |
| AUDITOR | ✓ |

- Cashier without permission: no "Göster" button visible
- User with permission: "Göster" toggle on each row
- Click "Göster": full phone revealed for that row
- Audit event: `party_phone_unmasked` (party_id, user_id, timestamp)

## Aging display in search list

**Minimal only.** Display:
- Balance (with sign indicator: borç/alacak)
- Limit warning chip if applicable

Detail aging (90+ overdue, 60-90, etc.) **NOT shown in search list**. Reasons:
- 10-min stale mview data
- Cognitive overload during fast customer lookup
- Credit decision happens at payment time (3.A.5) with fresh DB read

## Speed budget

| Action | p95 target |
|---|---|
| Open modal | < 80ms |
| First search | < 350ms |
| Phone suffix match | < 200ms |
| Select + close | < 200ms |

## Permissions

- `sales.create` (inherited)
- `parties.create` (quick-create)
- `parties.view_full_phone` (unmask toggle)

## Edge cases

| # | Scenario | Behavior |
|---|---|---|
| 1 | Customer BLOCKED | Red badge "BLOKE" in result; selection allowed but server rejects at attach |
| 2 | Customer over credit limit | Orange chip "Limit aşıldı: ₺X"; selection allowed, decision at payment |
| 3 | Multiple matches same phone last-7 | All shown, name disambiguates |
| 4 | Customer not found | "Yeni müşteri ekle" button (3.A.3.b) |
| 5 | Already attached customer | Modal reopens with chip + "Müşteriyi kaldır" button |
| 6 | Network error | Inline retry banner |
| 7 | Customer is employee | parties.role contains CUSTOMER + EMPLOYEE; allowed |

## Layout

```
┌─ Modal (centered, ~50% screen) ─────────────────────────────────┐
│                                                                   │
│   ⌕ [Telefon, isim, e-posta veya vergi no...]      [×] kapat    │
│                                                                   │
│   ┌─ Currently attached (if any) ──────────────────────────┐   │
│   │ Şu an seçili: Ahmet Yılmaz · 0532 *** 1234              │   │
│   │ [Müşteriyi kaldır]                                       │   │
│   └──────────────────────────────────────────────────────────┘   │
│                                                                   │
│   ┌─ Results (scrollable, virtualized) ──────────────────┐      │
│   │ ▶ Ahmet Yılmaz                                       │      │
│   │   0532 *** 1234  [Göster]  Bakiye: ₺450 (borç)      │      │
│   │   [Limit aşıldı]                                      │      │
│   │                                                       │      │
│   │   Ayşe Demir                                          │      │
│   │   0533 *** 4567  [Göster]  Bakiye: ₺0                │      │
│   │                                                       │      │
│   │   Mehmet Kaya  [BLOKE]                                │      │
│   │   0535 *** 7890  [Göster]  Bakiye: -₺2100 (alacak)   │      │
│   └──────────────────────────────────────────────────────┘      │
│                                                                   │
│   Bulunamadı?  [+ Yeni müşteri ekle (Ctrl+N)]                    │
│                                                                   │
│   [Esc Kapat]  [Enter Seç]  [↑↓ Gezin]                           │
│                                                                   │
└───────────────────────────────────────────────────────────────────┘
```

## Balance sign convention

- Positive = customer owes us ("borç")
- Negative = we owe customer (credit balance, "alacak")
- Always displayed with text suffix to remove ambiguity

## Implementation notes

- Phone normalization library: libphonenumber-java (server-side)
- Mantine Modal, search input is TextInput with leftIcon
- Default-filter "stokta var" not applicable here
- Bakiye via `customer_aging_summary` mview; payment screen uses fresh DB read

---

## 3.A.3.b — Quick Customer Create (sub-modal)

> **Trigger:** "Yeni müşteri ekle" button from 3.A.3 (or Ctrl+N)

### Purpose

Create a new customer Party inline without leaving POS. Minimal fields only.

### Why allowed (unlike "new product")

Customer mistakes have low blast radius:
- Wrong phone → next sale won't find them, easy to correct
- Duplicate customer → can be merged later (admin tool v1.1+)
- No cascading financial impact (credit limit starts at 0)

Product mistakes cascade: wrong VAT, wrong cost, sale-and-purchase side effects.

### Reads

None.

### Writes

- `POST /parties`
  - Body: `{ roles: ['CUSTOMER'], display_name, phone }`
  - Returns: `{ id, ... }`
- Auto-follows with `PATCH /sales/{id}/customer { party_id }`

### Optimistic UI

NO. Creation is rare path. Wait for server confirmation (~500ms).

### Form fields (MVP minimum)

| Field | Required | Notes |
|---|---|---|
| Ad Soyad | Yes | Min 2 chars |
| Telefon | No (recommended) | Server-side E.164 normalization |

**Removed from quick-create**: email, tax_id. These go in back-office Party edit (Phase 3.G).

### Duplicate phone behavior

Server: `POST /parties` with existing phone (same tenant) → 409 with existing party:

```json
{
  "code": "PHONE_ALREADY_EXISTS",
  "existing_party": {
    "id": "...",
    "display_name": "Ahmet Yılmaz",
    "phone_masked": "0532 *** 1234"
  }
}
```

Sub-modal transforms:

```
Bu telefon zaten kayıtlı:
  Ahmet Yılmaz · 0532 *** 1234

[Mevcut müşteriyi kullan]  [İptal]
```

- "Mevcut kullan" → PATCH /sales/{id}/customer { party_id }
- "İptal" → return to 3.A.3 to enter different info
- **No force-create option in MVP** (would split current account). v1.1+ admin permission for this.

### Permissions

`parties.create`

### Keyboard flow

- On open: focus → name field
- Tab: name → phone → "Kaydet" → "İptal"
- Enter on any field: submit if valid
- Esc: cancel, return to 3.A.3

### Layout

```
┌─ Sub-modal (smaller, centered) ──────────────────────────────────┐
│                                                                    │
│   Yeni Müşteri                                       [×] kapat    │
│                                                                    │
│   Ad Soyad *                                                       │
│   [_____________________________________]                          │
│                                                                    │
│   Telefon                                                          │
│   [0_____________]                                                 │
│                                                                    │
│   [İptal (Esc)]                  [Kaydet ve seç (Enter)]          │
│                                                                    │
└────────────────────────────────────────────────────────────────────┘
```

### Edge cases

| # | Scenario | Behavior |
|---|---|---|
| 1 | Validation error | Inline field errors, form stays open |
| 2 | Duplicate phone | Modal transforms to "Mevcut kullan / İptal" |
| 3 | Network error | Retry button + auto-retry 5s |
