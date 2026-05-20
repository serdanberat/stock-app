# 3.A.6 — Terminal Pending / Status Recovery

> **Status:** Locked (Phase 3.A)
> **Sub-state of:** 3.A.5 Payment Screen
> **Trigger:** Tender enters AWAITING_TERMINAL or TIMEOUT

## Purpose

UI sub-state of 3.A.5 entered when a CARD tender is in AWAITING_TERMINAL or TIMEOUT status. Makes the cashier's interaction with terminal latency and failure explicit.

Not a separate route. Same `/pos` URL, tender workspace area swaps to terminal status view.

## Entry/exit

Automatically when tender transitions to AWAITING_TERMINAL. Persists until tender reaches terminal status (APPROVED, DECLINED, TIMEOUT, CANCELLED_BY_CASHIER, CANCELLED_BY_MANAGER).

## Reads

`GET /sales/{id}` polled every 2s while tender non-terminal. TanStack Query stops on terminal state.

## Writes

| Endpoint | Initiator |
|---|---|
| `POST /sales/{id}/tenders/{tenderId}/cancel` | Cashier (CANCELLED_BY_CASHIER) |
| `POST /sales/{id}/tenders/{tenderId}/terminal-callback` | Terminal integration (system) |

Manager review during TIMEOUT also dispatches cancel with override token (CANCELLED_BY_MANAGER).

## TIMEOUT resolution policy

**No manual APPROVED.** This is the most important fraud-prevention decision on this screen.

When TIMEOUT reached:
- Tender stays in TIMEOUT state (non-terminal, blocks Sale.complete)
- Manager has TWO options only:
  - **Cancel this payment, take a new one** (TIMEOUT → CANCELLED_BY_MANAGER)
  - **Void the entire sale** (Sale → VOIDED)
- Manager **cannot mark APPROVED**. No UI for it.

### Why

Phantom card charge is the worst POS failure mode. Bank-side reversal handles "terminal charged but no sale": automated or manual within 1-2 days. POS system pushes this responsibility to bank infrastructure rather than trusting cashier judgment.

v1.1+: real terminal adapters may add transaction-query capability for automated reconciliation. MVP relies on manager + bank reconciliation.

## Late callback handling

Server-side: if callback arrives after CANCELLED_BY_* or TIMEOUT:
- Store callback details on tender record
- **Do NOT flip status** back to APPROVED
- Emit `SaleReconciliationRequired` event
- Manager dashboard surfaces the event

### Cashier notification

**Only if same active session**. Sade approach:

| Cashier state | Notification |
|---|---|
| Same active register session | Push banner via 30s polling |
| Different session / inactive / different store | Manager dashboard only |

No notification queue, no replay on next login. Manager dashboard is source of truth for inactive cashier notifications.

Banner persistence: until cashier dismisses or 24h auto-dismiss.

## Optimistic UI

None. Status driven entirely by server polling.

## Locking

None at this screen level.

## Keyboard flow

### AWAITING_TERMINAL

| Key | Action |
|---|---|
| Esc | Cancel dispatch (confirm modal → POST cancel → CANCELLED_BY_CASHIER) |
| Tab | Inactive (no focusable elements) |
| Enter | Inactive |

### TIMEOUT

| Key | Action |
|---|---|
| Esc | Returns to payment screen tender selection |
| Enter | Opens "Manager review required" modal |

## Barcode flow

Scanner disabled (inherits 3.A.5).

## Speed budget

| Action | p95 target |
|---|---|
| Poll interval | 2000ms |
| Status render | < 50ms |
| Cancel dispatch | < 600ms (includes terminal abort) |

## Permissions

- `sales.create` (inherited)
- `sales.tender.cancel_during_terminal` (cashier can cancel own session)
- `sales.tender.resolve_timeout` (manager only, with override token)

## Edge cases

| # | Scenario | Behavior |
|---|---|---|
| 1 | Network drop during polling | TanStack Query retries; yellow banner "Bağlantı sorunu" |
| 2 | Cashier Esc to cancel | Confirm modal; if terminal already approved (race), 409, UI shows "Terminal işlemi tamamladı, callback bekleniyor" |
| 3 | Tab loses focus | Polling pauses (refetchOnWindowFocus); resume on focus |
| 4 | 90s timer elapsed | Server flips status to TIMEOUT; UI swaps to TIMEOUT view |
| 5 | Late callback after CANCELLED_BY_CASHIER | Reconciliation flag + event; banner if cashier active in same session |
| 6 | Late callback after CANCELLED_BY_MANAGER | Same as 5 |
| 7 | Late callback after VOIDED | Orphan charge; manager investigates via back-office |

## Layout — AWAITING_TERMINAL

```
┌─ Tender workspace ───────────────────────────────────────────────┐
│                                                                   │
│  Kart İşlemi                                                      │
│  ─────────────────                                                │
│  Tutar: ₺700,00                                                   │
│  Terminal: TER-001 (Ingenico iWL250)                              │
│                                                                   │
│  ┌─ Status ─────────────────────────────────────────────────┐  │
│  │                                                             │  │
│  │     ⌛  Müşteri kartını okutuyor...                         │  │
│  │                                                             │  │
│  │     ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━                │  │
│  │     23s / 90s                                              │  │
│  │                                                             │  │
│  └─────────────────────────────────────────────────────────────┘  │
│                                                                   │
│  Lütfen müşterinin kartı okutmasını bekleyin.                    │
│  Terminal yanıtı geldiğinde otomatik devam edecek.               │
│                                                                   │
│  [İptal et (Esc)]                                                 │
│                                                                   │
└───────────────────────────────────────────────────────────────────┘
```

## Layout — TIMEOUT

```
┌─ Tender workspace ──────────────────────────────────────────────┐
│                                                                   │
│  ⚠  Terminal Yanıt Vermedi                                       │
│  ─────────────────────────                                       │
│  Kart: TER-001                                                   │
│  Tutar: ₺700,00                                                  │
│  Süre: 90s aşıldı                                                 │
│                                                                   │
│  ┌─ Ne yapmalı? ─────────────────────────────────────────────┐ │
│  │                                                              │ │
│  │  Manuel onay verilmez. Yönetici incelemesi gerekli.          │ │
│  │                                                              │ │
│  │  Yönetici seçenekleri:                                       │ │
│  │  • Bu ödemeyi iptal et, yeniden ödeme al                   │ │
│  │  • Tüm satışı iptal et                                       │ │
│  │                                                              │ │
│  │  Bu satış yöneticisiz tamamlanamaz.                          │ │
│  │                                                              │ │
│  └──────────────────────────────────────────────────────────────┘ │
│                                                                   │
│  [Yöneticiyi çağır]                                               │
│                                                                   │
└───────────────────────────────────────────────────────────────────┘
```

## Manager review modal (from TIMEOUT)

```
┌─ Manager Review Modal ─────────────────────────────────────────┐
│                                                                   │
│  Onaylanmayan Kart İşlemi                                         │
│  ───────────────────────                                         │
│  Sale: #DRAFT-78ab23                                              │
│  Tutar: ₺700,00                                                   │
│  Terminal: TER-001                                                │
│  Süre: 92s                                                        │
│                                                                   │
│  Yönetici PIN: [______]                                           │
│  Sebep: [Terminal yanıt vermedi ▾]                                │
│                                                                   │
│  Karar:                                                           │
│  ◯  Bu ödemeyi iptal et (sebep: yönetici kararı)                │
│  ◯  Tüm satışı iptal et (sale VOIDED)                           │
│                                                                   │
│  [İptal]                              [Uygula]                    │
│                                                                   │
└───────────────────────────────────────────────────────────────────┘
```

## Late callback banner (in POS shell)

```
┌──────────────────────────────────────────────────────────────────┐
│ ⚠ Önceki satış #2026-1233 için terminal sonradan yanıt verdi:    │
│   APPROVED. Yöneticiye bildir.                          [Detay] [×] │
└──────────────────────────────────────────────────────────────────┘
```

- Appears in POS top area (visible across 3.A.1 / 3.A.5 / 3.A.7)
- Non-blocking; cashier work continues
- Dismissed by user click or 24h auto-dismiss
- Polling every 30s for new notifications

## Audit events

- `tender_dispatched` (entering AWAITING_TERMINAL)
- `tender_approved` (callback success)
- `tender_declined` (callback declined)
- `tender_timeout` (90s elapsed)
- `tender_cancelled_by_cashier`
- `tender_cancelled_by_manager`
- `tender_timeout_resolved` (manager decision)
- `sale_reconciliation_required` (late callback after termination)

## Implementation notes

- 90s timer is server-side (authoritative). Client progress bar is purely visual.
- Tab visibility detection via TanStack Query `refetchOnWindowFocus: true`, `intervalInBackground: false`
- Manager PIN flow reuses 3.A.4 override token infrastructure
- Late callback notification polling: separate query, 30s interval, runs only on POS routes
- WebSocket upgrade v1.1+ if terminal UX problem becomes visible (MVP polling sufficient for nominal load)
