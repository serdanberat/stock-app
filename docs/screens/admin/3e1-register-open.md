# 3.E.1 — Cash Register Open

> **Status:** Locked (Phase 3.E)
> **Route:** `/cash-register/open`

## Purpose

Open a register session at start of shift / day. Captures opening cash float. Required before POS sales can be made.

## Aggregate ownership (explicit)

- **Writes** CashRegisterSession aggregate (state machine)
- On open, indirectly via outbox event consumer:
  - `cash_movement` OPENING_FLOAT with opening cash count

## Critical invariant

**One OPEN session per `(store_id, register_id)` at any time.** NOT per user — supports shift handover with same register.

Server enforces via partial UNIQUE index:
```sql
CREATE UNIQUE INDEX ... ON cash_register_sessions
  (tenant_id, store_id, register_id)
  WHERE status = 'OPEN';
```

## State machine

```
    CLOSED → OPEN → CLOSED
```

- Open: requires `opening_float_amount`
- Close: requires reconciliation (3.E.2)

## Reads

- `GET /cash-register/current?store_id=&register_id=`
  - Returns current OPEN session if any; null if closed
  - If OPEN exists from previous day: returns it + `orphan_flag=true`
- `GET /stores` — User's accessible stores

## Writes

- `POST /cash-register/open`
  - Body: `{ store_id, register_id, opening_float_amount, note? }`
  - Idempotency-Key required
  - Server validates: no OPEN session exists for (store, register)
  - If exists: 409 with `orphan_session_id`

## Orphan OPEN session recovery flow

Scenario: power outage, browser crash, tablet broke. Previous day session never closed.

Next-day open attempt:
1. Server detects existing OPEN session
2. UI shows recovery modal: "Bu kasada {N} gün önce başlayan açık oturum var. Manager kapatması gerekli."
3. Two paths:
   - **STORE_MANAGER+ permission**: close orphan session with reconciliation note (counted_cash = whatever physically in drawer; variance becomes adjustment movement)
   - **Lower role**: cannot proceed; redirect to call manager

Server endpoint: `POST /cash-register/sessions/{id}/force-close`
- Body: `{ closing_cash_count, reconciliation_note (min 20 chars), reason: 'ORPHAN_RECOVERY' }`
- Requires `force_close_orphan` permission
- Audit event: `cash_session_force_closed_orphan`

## Optimistic UI

NO. Session open is consequential (gates all POS sales).

## Keyboard flow

| Key | Action |
|---|---|
| Tab | store → register → opening_float → note → Open |
| `Ctrl+S` | Open session |
| `Esc` | Cancel |

## Speed budget

| Action | p95 target |
|---|---|
| Open submit | < 600ms |

## Permissions

| Permission | Default |
|---|---|
| `cashregister.open` | CASHIER+, STORE_MANAGER+ |
| `cashregister.force_close_orphan` | STORE_MANAGER+ |

## Layout — normal open

```
┌─ Kasayı Aç ───────────────────────────────────────────────────────┐
│                                                                    │
│  Mağaza:     [Beyoğlu ▾]                                          │
│  Kasa:       [Kasa 1 ▾]                                            │
│                                                                    │
│  Açılış nakit miktarı:                                             │
│  [₺ 500,00]                                                        │
│                                                                    │
│  Not (opsiyonel):                                                  │
│  [_______________________________]                                 │
│                                                                    │
│  [Esc İptal]                              [Aç (Ctrl+S)]            │
│                                                                    │
└────────────────────────────────────────────────────────────────────┘
```

## Layout — orphan recovery

```
┌─ ⚠ Açık Kasa Oturumu Bulundu ──────────────────────────────────────┐
│                                                                    │
│  Bu kasada (Beyoğlu - Kasa 1) açık oturum var:                    │
│  Başlangıç: 14/05 09:00 (2 gün önce)                              │
│  Kasiyer: Ayşe Yılmaz                                              │
│  Açılış nakit: ₺500,00                                             │
│  Tahmini güncel: ₺1.245,00                                         │
│                                                                    │
│  Manager onayı ile force-close yapılabilir.                        │
│                                                                    │
│  Yönetici PIN: [______]                                            │
│  Fiili nakit sayım: [₺ ____,___]                                   │
│  Açıklama (min 20 karakter):                                      │
│  [______________________________________________]                  │
│                                                                    │
│  [İptal]                              [Force Close]                │
│                                                                    │
└────────────────────────────────────────────────────────────────────┘
```

## Edge cases

| # | Scenario | Behavior |
|---|---|---|
| 1 | User opens at store they're not assigned | Store dropdown limited to assigned stores |
| 2 | Negative opening_float | Client + server validation reject |
| 3 | Concurrent open by two users (race) | UNIQUE index serializes; one succeeds, other 409 |
| 4 | Force close with cash variance | Difference between expected and counted creates cash_movement CORRECTION at force-close; audit captures variance + reason |

## Audit events

- `cash_session_opened`
- `cash_session_force_closed_orphan`
- `cash_session_open_blocked_orphan_exists`

## Implementation notes

- Standard Mantine form
- Force-close requires manager PIN per 3.A.4 pattern
- Partial UNIQUE index on `(tenant_id, store_id, register_id) WHERE status='OPEN'` enforces invariant at DB level
