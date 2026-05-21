# 3.D.3 — Return / Exchange Initiate

> **Status:** Locked (Phase 3.D)
> **Routes:**
> - `/finance/returns/new` — Reference-based path
> - `/finance/returns/new?sale_id={id}` — Deeplink from POS
> - `/finance/returns/new?mode=without_reference` — No original sale

## Purpose

Entry point for post-sale returns and exchanges. Cashier selects "Yeni İade" from POS shell OR scans receipt to begin.

Two paths:
- **Reference-based**: original sale known (preferred)
- **Reference-less**: customer has no receipt (restricted, audited)

## Aggregate ownership (explicit)

- **Reads** Sale aggregate (if reference-based)
- **Reads** ProductVariant (for catalog lookup)
- **Creates** Return aggregate (DRAFT state)

## Mode A: reference-based

Cashier provides sale identifier:
- Sale number (PI-2026-1234) typed
- Scan receipt barcode (QR or Code128 of sale_id)
- Search by customer + recent sales

Server validates:
- Sale exists, status = COMPLETED
- Sale within tenant's `return_window_days` (default 30)
- No prior return on same sale exceeds remaining quantity

UI loads sale lines, lets cashier select which lines + quantities to return.

## Mode B: reference-less (without_sale_reference)

Cashier explicitly initiates "Fişsiz İade" path.

Required:
- Manager PIN override (per 3.A.4 pattern)
- Reason from closed set:
  - `NO_RECEIPT_KEPT` — Fiş tutulmamış
  - `RECEIPT_LOST` — Fiş kayıp
  - `GIFT_NO_RECEIPT` — Hediye - fiş alıcıda
  - `RECEIPT_FROM_ANOTHER_STORE` — Başka mağazadan, kontrol edilemiyor
- Free-text note (mandatory; minimum 10 chars)

### Refund restrictions (CRITICAL)

Reference-less return CAN refund via:
- ✓ `STORE_CREDIT` (issued to customer account)
- ✓ `CUSTOMER_ACCOUNT` (debt reduction if customer has debt)

Reference-less return CANNOT refund via:
- ✗ CASH
- ✗ CARD_REFUND

Server enforces these rules; UI hides forbidden options.

Rationale: fraud surface in reference-less returns is large. Store credit + customer account require attached customer party, creating audit trail. Cash/card refund without sale reference is the highest fraud risk path; not supported MVP.

## Reads

- `GET /sales/{id}` — Reference-based path
- `POST /sales/search` — Customer history search
- `POST /parties/search` — Customer lookup
- `POST /catalog/variants/search` — Reference-less line entry
- `GET /tenant/return-settings` — `return_window_days`, etc.

## Writes

- `POST /finance/returns`
  - Body:
    ```
    {
      mode: 'REFERENCED' | 'WITHOUT_REFERENCE',
      original_sale_id?,          // null in WITHOUT_REFERENCE
      customer_party_id?,         // recommended; required for store credit / customer account refund
      store_id,
      reason_code?,               // required for WITHOUT_REFERENCE
      manager_override_token?,    // required for WITHOUT_REFERENCE
      note?
    }
    ```
  - Creates DRAFT return; navigates to `/finance/returns/{id}` (3.D.4)

## Optimistic UI

NO at create (validates server-side; awaits response).

## Locking

Optimistic version on Sale aggregate (when reference-based) to prevent stale-sale return.

## Keyboard flow

| Key | Action |
|---|---|
| Tab | mode selector → sale lookup / customer lookup → next |
| ⌕ | Scanner reads receipt barcode (mode A) or product barcode (mode B) |
| Enter | Submit lookup; confirm initiation |
| Esc | Cancel |

## Barcode flow

- Mode A: scanner expects receipt barcode (sale_id or sale_number)
- Mode B: scanner DISABLED (no specific item context yet)

## Speed budget

| Action | p95 target |
|---|---|
| Sale lookup | < 400ms |
| Customer search | < 350ms |
| Return DRAFT creation | < 500ms |

## Permissions

| Permission | Default |
|---|---|
| `returns.initiate` | STORE_MANAGER+, CASHIER |
| `returns.initiate_without_reference` | STORE_MANAGER+ (requires PIN) |

## Edge cases

| # | Scenario | Behavior |
|---|---|---|
| 1 | Sale outside return window | Lookup succeeds with warning "Bu satış iade süresi dışında (45 gün önce). Yine de devam?"; requires manager override + reason RETURN_OUTSIDE_WINDOW |
| 2 | Sale was ADMINISTRATIVELY_REVERSED | Lookup blocked: "Bu satış iptal edilmiş. İade alınamaz." |
| 3 | Sale fully returned previously | Lookup shows remaining quantities = 0; banner "Bu satışın iade hakkı tamamen kullanılmış." |
| 4 | Customer scans receipt but lines partially returned | 3.D.4 shows lines with remaining qty (bought - returned) |
| 5 | Reference-less return without customer party | Refund tender options reduced further: only STORE_CREDIT (requires customer attachment); flow blocks until customer attached |
| 6 | Manager PIN lockout in WITHOUT_REFERENCE flow | 3-fail lockout per 3.A.4 pattern; cannot initiate; flow halts |

## Layout — Mode A entry

```
┌─ Yeni İade Başlat ────────────────────────────────────────────────┐
│                                                                    │
│  ◉  Fiş ile İade                                                   │
│  ◯  Fişsiz İade (yönetici onayı gerekir)                          │
│                                                                    │
│  Fiş arama:                                                        │
│  Fiş No: [PI-2026-1234]                                            │
│  Veya: ⌕ [Müşteri ara]                                             │
│  Veya: Fişi tara (barkod)                                          │
│                                                                    │
│  ┌─ Bulunan satış (lookup sonrası) ──────────────────────────┐  │
│  │ Satış: PI-2026-1234                                          │  │
│  │ Tarih: 12/05/2026                                            │  │
│  │ Müşteri: Ahmet Yılmaz                                        │  │
│  │ Toplam: ₺ 700,00                                             │  │
│  │ Mağaza: Beyoğlu                                              │  │
│  │                                                              │  │
│  │ Lines (iade için seçilebilir 3.D.4'te):                      │  │
│  │   T-shirt Black/M × 2  (max iade: 2)                         │  │
│  │   Jeans Blue/32 × 1   (max iade: 1)                          │  │
│  │   Sweater Red/L × 1   (max iade: 0 - daha önce iade edildi) │  │
│  └──────────────────────────────────────────────────────────────┘  │
│                                                                    │
│  [Esc İptal]                              [İade Başlat]            │
│                                                                    │
└────────────────────────────────────────────────────────────────────┘
```

## Layout — Mode B (without reference)

```
┌─ Yeni İade Başlat — Fişsiz ──────────────────────────────────────┐
│                                                                    │
│  ⚠ Fişsiz iade. Sadece store credit/cari hesap iade verilebilir.  │
│     Nakit/kart iadesi yapılamaz.                                   │
│                                                                    │
│  Müşteri (zorunlu): ⌕ [Ara veya tara]                              │
│  Mağaza: [Beyoğlu ▾]                                              │
│  Sebep:  [Fiş Kayıp ▾]                                             │
│  Açıklama: [En az 10 karakter...]                                  │
│                                                                    │
│  Yönetici PIN: [______]                                            │
│                                                                    │
│  [Esc İptal]                              [İade Başlat]            │
│                                                                    │
└────────────────────────────────────────────────────────────────────┘
```

## Audit events

- `return_initiated_with_reference`
- `return_initiated_without_reference` (with reason + actor)
- `return_outside_window_overridden` (with reason)

## Implementation notes

- Mode toggle persists URL `?mode=`
- Manager PIN flow reuses 3.A.4 override token pattern
- Reason dropdown closed set; no free-text reason (note is separate)
- Customer required for WITHOUT_REFERENCE refund tender allowlist
