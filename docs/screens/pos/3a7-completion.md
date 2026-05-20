# 3.A.7 — Completion / Receipt Screen

> **Status:** Locked (Phase 3.A)
> **Trigger:** Successful `POST /sales/{id}/complete`
> **State:** Sale.status = COMPLETED

## Purpose

Confirm Sale.complete success to the cashier. Provide receipt actions (print, email). Brief screen (3-10 seconds typical), then return to fresh POS state ready for next sale.

The only "success" screen in the POS flow. Designed for fast acknowledgment, not data review.

## Reads

- `GET /sales/{id}`
  - Final sale snapshot, includes sale_number allocated server-side
- `GET /sales/{id}/document`
  - Polled every 1s until status = READY or FAILED (terminal states)
  - Returns: `{ id, status, pdf_url, ready_at }`

## Writes

| Endpoint | Purpose |
|---|---|
| `POST /sales/{id}/document/print` | Trigger print (returns immediately) |
| `POST /sales/{id}/document/email` | Trigger email dispatch |

**SMS endpoint removed from MVP.** No `POST /sms`. v1.1+ feature.

## Optimistic UI

| Action | Behavior |
|---|---|
| Print click | Button → "Kuyruğa alındı ✓" 5s, then resets to "F9 Yazdır" |
| Email click | Modal opens; on send → "E-posta sıraya alındı ✓" 5s, then resets |

Honest labels: "queued" not "done". Print/email dispatch is asynchronous; actual delivery happens in worker pattern (Phase 6.F).

## Document async resolution

PDF generation is asynchronous (worker pattern). Sale is COMPLETED but PDF may not be READY immediately.

| Elapsed | UI state |
|---|---|
| 0-2s | "Fiş hazırlanıyor..." spinner |
| 2-10s | "Yazıcı kuyruğunda..." (if still PENDING_GENERATION) |
| 10s+ | "Fiş hazırlanıyor — biraz uzun sürüyor. Sonra geçmiş satışlardan ulaşabilirsiniz." |
| READY | Buttons enabled |
| FAILED | "Fiş oluşturulamadı" + retry button |

Cashier can proceed to "Yeni Satış" WITHOUT waiting for PDF. Sale is committed; document generation is background-only.

## Locking

None.

## Keyboard flow

On enter: focus → "Yeni Satış" button (default action).

| Key | Action |
|---|---|
| Enter / Space | Yeni Satış (return to 3.A.1, fresh cart) |
| Esc | Yeni Satış |
| F9 | Reprint receipt (queue another print job) |
| F6 | Email receipt (modal with email field) |

No "back" — sale COMPLETED, immutable from cashier's perspective. Corrections via Return flow (Phase 3.E).

## Barcode flow

**Scanner active.** Scanning a barcode here automatically:
1. Triggers "Yeni Satış" (returns to 3.A.1 with fresh cart)
2. Forwards scanned barcode to new sale's add-item pipeline

Matches cashier muscle memory: complete one sale, immediately scan next customer's first item, no manual screen transition.

## Speed budget

| Action | p95 target |
|---|---|
| Screen render | < 200ms |
| First document status poll | < 100ms after mount |
| Document READY | < 2s (Gotenberg single-page) |
| Print dispatch | < 300ms |
| "Yeni Satış" return | < 150ms |

## Permissions

- `sales.create` (inherited; post-complete state of own sale)
- `sales.reprint_receipt` (CASHIER default has)
- Email receipt: no special permission MVP

## Print retry policy

If print job fails (printer offline):
- Worker retries 3 times: 30s / 2m / 10m backoff
- 3 fails → printer down event + Sentry alert + manager dashboard notification
- Cashier does NOT see retry detail (would be noisy)
- Reprint manually via F9 (queues another job)

## Edge cases

| # | Scenario | Behavior |
|---|---|---|
| 1 | Document generation fails | "Fiş otomatik oluşturulamadı" + Tekrar Dene button; sale unaffected |
| 2 | Printer offline | Print queued; "Yazıcı kuyruğunda" 5s; manager alert via Sentry |
| 3 | "Yeni Satış" before PDF ready | Allowed; generation continues in background; retrieve via Sale History |
| 4 | Email modal: no email on customer | Cashier types email; one-time send; NOT saved to customer (KVKK consent flow separate) |
| 5 | Cashier session terminates | Committed Sale unaffected; next cashier sees in Sale History |
| 6 | Reprint after sale_administratively_reversed | Receipt shows "İPTAL EDİLDİ" watermark + reversal reference |

## Layout

### Default

```
┌─ Full-screen completion view ────────────────────────────────────┐
│                                                                    │
│                       ✓ Satış Tamamlandı                          │
│                       ────────────────────                         │
│                                                                    │
│                       Sale: #2026-1234                             │
│                       Toplam: ₺700,00                              │
│                       Saat: 14:32                                  │
│                                                                    │
│  ┌─ Ödemeler ─────────────────────┐  ┌─ Fiş ─────────────────┐ │
│  │  Nakit:     ₺500                 │  │  ⌛ Hazırlanıyor...   │ │
│  │  Kart:      ₺200                 │  │                       │ │
│  │  Para üstü: ₺0                   │  │  [F9 Yazdır] (disabled│ │
│  │                                  │  │     until ready)      │ │
│  │  Müşteri: Ahmet Yılmaz           │  │  [F6 E-posta]         │ │
│  │  Yeni bakiye: ₺450 (borç)        │  │                       │ │
│  └──────────────────────────────────┘  └───────────────────────┘ │
│                                                                    │
│              ┌──────────────────────────────────┐                  │
│              │   [Enter] YENİ SATIŞ              │                  │
│              │   (or scan next item)             │                  │
│              └──────────────────────────────────┘                  │
│                                                                    │
└────────────────────────────────────────────────────────────────────┘
```

### Document READY

```
┌─ Fiş ──────────────────────────────────────┐
│  ✓ Fiş hazır                                 │
│                                                │
│  [F9 Yazdır]  [F6 E-posta]                    │
└──────────────────────────────────────────────┘
```

### Print clicked (5s feedback)

```
┌─ Fiş ──────────────────────────────────────┐
│  ✓ Fiş hazır                                 │
│                                                │
│  [Kuyruğa alındı ✓]  [F6 E-posta]            │
└──────────────────────────────────────────────┘
```

After 5s, button reverts to `[F9 Yazdır]`.

### Document FAILED

```
┌─ Fiş ──────────────────────────────────────┐
│  ⚠ Fiş oluşturulamadı                        │
│  Geçmişten manuel deneyebilirsiniz.          │
│                                                │
│  [Tekrar Dene]                                │
└──────────────────────────────────────────────┘
```

**No PDF thumbnail in MVP.** Status text + buttons only. Thumbnail v1.1+.

## "Yeni Satış" flow

| Key | Action |
|---|---|
| Enter / Space / Esc | Return to /pos (3.A.1) |
| Barcode scan | Return to /pos AND forward scan to add-item pipeline |

Implementation:
1. Clear current Zustand sale state
2. Reset client_cart_id (new UUID on next item add)
3. Reset idempotency key store
4. Navigate to /pos (pre-cart state)
5. If triggered by scan: forward barcode to add-item

## Email receipt modal (F6)

```
┌─ E-posta ile Fiş Gönder ────────────────────────────────────────┐
│                                                                   │
│   E-posta adresi:                                                 │
│   [_________________________________]                             │
│                                                                   │
│   ⚠ Tek seferlik gönderim. Müşteri kaydına eklenmez.            │
│                                                                   │
│   [İptal]                              [Gönder]                   │
│                                                                   │
└───────────────────────────────────────────────────────────────────┘
```

- Email NOT saved to customer party without explicit consent flow (KVKK)
- One-time send via external consumer (Phase 6.F)

## Implementation notes

- Document polling: TanStack Query `refetchInterval` stops on terminal state (READY/FAILED)
- Cash drawer opens at completion (per 3.A.5 security note); audit event `cash_drawer_opened` with reason SALE_COMPLETE
- Sound feedback: optional "ka-ching" / beep, config in user prefs (not tenant)
- No timeout on this screen; cashier acts when ready
- Print/email button feedback duration: 5s, then resets
- PDF thumbnail: removed from MVP scope (v1.1+ visual richness)
