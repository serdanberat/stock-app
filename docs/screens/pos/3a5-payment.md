# 3.A.5 — Payment Screen

> **Status:** Locked (Phase 3.A)
> **State:** Sale in AWAITING_PAYMENT
> **Trigger:** F12 from POS Main Sale → `POST /sales/{id}/proceed-to-payment`

## Purpose

Collect tender(s) for a Sale. Transitions Sale through:
```
DRAFT → AWAITING_PAYMENT → COMPLETED
```

Supports multi-tender (split between cash + card + customer account). Authoritative state lives server-side; client renders.

This is the most fraud-sensitive, race-prone, and reconciliation-critical screen in the system. Every design choice prioritizes correctness over speed.

## State machine entry/exit

### Enter

- `POST /sales/{id}/proceed-to-payment` from 3.A.1
- Server validates: Sale.status=DRAFT, items.count > 0, store open, register session open, customer constraints
- Server transitions to AWAITING_PAYMENT
- **Server LOCKS pricing mutations** (no discount/qty/customer change allowed)
- Server returns frozen Sale snapshot

### Exit paths

| Path | Trigger | Effect |
|---|---|---|
| → COMPLETED | F12 Tamamla with all tenders settled | Atomic complete TX |
| → DRAFT | "Sepete dön" | Cancels DRAFT/AWAITING_TERMINAL tenders; reverses APPROVED CASH/CUSTOMER_ACCOUNT with confirm; CARD blocked |
| → VOIDED | Esc + confirm on empty payment | Tender state checked first |

### Disallowed at this state

- Any pricing/quantity/customer mutation
- Adding items
- Removing items
- Direct status manipulation

Server enforces via Sale aggregate invariant:

```java
public void addItem(...) { assertEditable(); }
private void assertEditable() {
    if (status != DRAFT) {
        throw new SaleNotEditableException(...);
    }
}
```

## Tender types (MVP)

| Type | Authoritative state |
|---|---|
| CASH | `cash_movements` (register session) |
| CARD | `payment_attempts` (terminal callback) |
| CUSTOMER_ACCOUNT | `account_movements` (party's debt account) |

GIFT_VOUCHER deferred to v1.1+ (separate aggregate with redemption state, partial use, expiry, fraud surface).

## Tender state machine (per tender, NOT Sale)

| State | Description |
|---|---|
| DRAFT | Cashier picked type + amount; not yet dispatched |
| AWAITING_TERMINAL | Card sent to physical terminal; awaiting callback |
| APPROVED | Tender accepted; counted toward total |
| DECLINED | Card declined; not counted |
| TIMEOUT | Terminal 90s no response; **non-terminal**; blocks Sale.complete |
| CANCELLED_BY_CASHIER | Esc during AWAITING_TERMINAL |
| CANCELLED_BY_MANAGER | Manager resolution during TIMEOUT |

```java
public boolean isNonTerminal() {
    return this == DRAFT || this == AWAITING_TERMINAL || this == TIMEOUT;
}
```

Distinct cancellation states enable forensic queries:
```sql
SELECT * FROM payment_attempts
WHERE status = 'CANCELLED_BY_MANAGER'
  AND late_callback_outcome = 'APPROVED'
  AND reconciliation_flag IS NULL;
```

## Reads

| Endpoint | Purpose |
|---|---|
| `GET /sales/{id}` | Frozen snapshot + tender status polling (2s) |
| `GET /parties/{customerId}/account-summary?fresh=true` | Fresh credit check (not 10min mview) |
| `GET /cash-registers/{registerId}/session-current` | Float check |

## Writes

| Endpoint | Purpose |
|---|---|
| `POST /sales/{id}/tenders` | Create tender (idempotent via `client_tender_id`) |
| `DELETE /sales/{id}/tenders/{tenderId}` | Cancel non-terminal tender |
| `POST /sales/{id}/tenders/{tenderId}/cash-confirm` | Cashier confirms cash received |
| `POST /sales/{id}/tenders/{tenderId}/terminal-callback` | Terminal integration callback (not cashier) |
| `POST /sales/{id}/complete` | **X-Idempotency-Key required** |
| `POST /sales/{id}/revert-to-draft` | Revert flow |

### Sale.complete atomic transaction

Single DB transaction:
1. Sale.status = COMPLETED
2. Stock OUT movements (per item, FOR UPDATE on stock_balances)
3. Cash movement (if cash tender, into register session)
4. Account movements (if customer account tender)
5. Payment records persisted
6. Sale document stub (PENDING_GENERATION)
7. Outbox event SaleCompletedV1

Server validates before TX:
- Sum of APPROVED tenders == grand_total (no over/under)
- No tender in non-terminal state
- Register session still open

## Optimistic UI

| Action | Optimistic? |
|---|---|
| Cash tender input | Preview yes |
| Cash tender confirm | Wait for server |
| Card tender dispatch | Wait for server |
| Card terminal status | Server-pushed (polled) |
| Customer account tender | Wait for server |
| Sale.complete | **NEVER optimistic** |

Hard rule: anything that mutates money or stock waits for server. POS feels slightly slower here — by design.

## Locking

Pessimistic SELECT FOR UPDATE during Sale.complete:
- sale row
- all stock_balances rows (sorted by variant_id ASC)
- cash_register_sessions row
- account_profiles row (if customer account tender)

Canonical lock acquisition order (Phase 2D):
1. sale
2. stock_balances
3. cash_register_sessions
4. account_profiles
5. outbox_global_sequence

## Idempotency

- `X-Idempotency-Key` header on Sale.complete (UUID generated client-side on first F12, retried unchanged)
- Stored in `idempotency_keys` table (Phase 2D), 7-day retention
- Tender posts use `client_tender_id` (same pattern)
- **NEVER complete a sale twice** — defense against double-stock-deduction

## Polling for terminal status

- Client polls `GET /sales/{id}` every 2s while tender in AWAITING_TERMINAL
- TanStack Query `refetchInterval: 2000` until terminal state
- `refetchOnWindowFocus`, `intervalInBackground: false`
- WebSocket upgrade v1.1+ if latency UX problem visible

## Keyboard flow

### Tender type selection

| Key | Action |
|---|---|
| 1 | Nakit (cash) |
| 2 | Kart (card) |
| 3 | Müşteri Hesabı (disabled if no customer) |

(SMS removed; gift voucher v1.1+.)

### Amount entry

- Numeric keys: type amount
- Enter: confirm + dispatch
- Tab: cycle tender type
- Backspace / Esc-while-entering: clear current

### After tender APPROVED

- Remaining > 0: focus returns to tender type selection
- Remaining == 0: focus on TAMAMLA button
- F12: Tamamla (enabled only when remaining == 0 AND no non-terminal tender)

### F-keys

| Key | Action |
|---|---|
| F2 | Customer panel (read-only) |
| F5 | Refresh customer credit (fresh GET) |
| F10 | Cancel APPROVED tender (manager override required) |
| Esc | Revert to DRAFT (with confirm if tenders posted) |

## Barcode flow

**Scanner DISABLED entirely.** Scanning during payment is always ambiguous. Cashier must revert to DRAFT to add items.

## Speed budget

| Action | p95 target |
|---|---|
| Screen render | < 200ms |
| Cash confirm | < 400ms |
| Card dispatch (client→server) | < 300ms |
| Terminal callback (external) | 5-30s typical |
| Customer credit check | < 500ms |
| Sale.complete | < 800ms |
| With terminal timeout race | < 5s feedback |

## Permissions

| Permission | Default |
|---|---|
| sales.complete | CASHIER |
| sales.tender.refund_approved_tender | Manager only (F10) |
| sales.tender.customer_account | CASHIER + customer with active account |
| sales.revert_after_approved_tender | Manager only |

## Credit limit override

When customer account tender > available credit:

```
Available credit: ₺50, requested: ₺200
→ UI: "Müsait kredi: ₺50. Devam için yönetici onayı."
→ Manager PIN flow (same as 3.A.4)
→ Reason mandatory (CreditOverrideReason enum)
→ Audit event credit_limit_exceeded_with_override
```

### Credit override reasons

| Code | Turkish |
|---|---|
| TRUSTED_REGULAR | Tanıdık müşteri |
| TEMPORARY_BREACH | Geçici aşım, ödeme yakında |
| MANAGER_DISCRETION | Yönetici takdiri |

## Cash overpayment

GROSS in + CHANGE_OUT separate movements:
```
₺200 received on ₺178 sale
→ cash_movement SALE_CASH_IN +₺200
→ cash_movement SALE_CHANGE_OUT -₺22
Net drawer: +₺178
```

Provides clarity at session-close reconciliation.

## Edge cases

| # | Scenario | Behavior |
|---|---|---|
| 1 | Overpayment cash | Para üstü calculated; two movements posted |
| 2 | Underpayment (split incomplete) | Tamamla disabled until remaining == 0 |
| 3 | Card TIMEOUT | **No manual APPROVED**; manager cancel or void only |
| 4 | Card declined | Red banner; retry / change tender / void |
| 5 | Credit insufficient | Manager PIN override flow |
| 6 | Customer blocked mid-payment | Customer tender disabled; remove customer or other tender |
| 7 | Register session closed | 409; modal "Satış nasıl tamamlansın?"; MVP VOID + audit |
| 8 | Stock changed since DRAFT | 409 INSUFFICIENT_STOCK; revert + reduce qty / void / negative-stock-override |
| 9 | Network drop during card dispatch | client_tender_id idempotency; retry |
| 10 | Network drop post-APPROVED, pre-complete | X-Idempotency-Key; retry returns same response |
| 11 | Cashier walks away post-APPROVED | Idle alert > 15min; manager investigates (no auto-void with APPROVED tender) |
| 12 | "Sepete dön" with APPROVED CASH | Confirm + reverse cash movement; audit `sale_reverted_with_approved_tenders` |
| 12b | "Sepete dön" with APPROVED CUSTOMER_ACCOUNT | Confirm + reverse account movement |
| 12c | "Sepete dön" with APPROVED CARD | **Blocked**; manager + back-office only |
| 13 | Mixed currency offer | Refused at UI (TRY only MVP) |
| 14 | Receipt printer unavailable | Sale.complete succeeds; print job queued |
| 15 | Power failure mid-complete | Atomic TX rollback; client retries via idempotency key |
| 16 | Two tabs same cashier | Idempotency + version check; one succeeds, other 409 |
| 17 | Concurrent Sale.complete (server race) | Single writer per Sale via idempotency UNIQUE constraint |

## Layout

### Default (no tenders yet)

```
┌─ Top bar ─────────────────────────────────────────────────────────┐
│ [Sepete dön (Esc)]   AWAITING_PAYMENT   Sale #DRAFT-78ab23       │
├──────────────────────────────────────┬───────────────────────────┤
│                                       │                            │
│  SALE SUMMARY (40%)                   │  TENDER WORKSPACE (60%)   │
│                                       │                            │
│  Customer: Ahmet Yılmaz               │  ┌─ Remaining ──────────┐ │
│  Tel: 0532 *** 1234                   │  │     ₺ 700,00          │ │
│  Bakiye: ₺450 (borç) [Limit aşıldı]   │  └──────────────────────┘ │
│                                       │                            │
│  ┌─ Items (read-only) ──────────┐    │  ┌─ Tender type ─────────┐│
│  │ T-shirt Black/M × 2   ₺198  │    │  │ [1 Nakit]               ││
│  │ Jeans Blue/32 × 1     ₺450  │    │  │ [2 Kart]                ││
│  │ Sweater Red/L × 1     ₺99   │    │  │ [3 Müşteri Hesabı]      ││
│  └──────────────────────────────┘    │  └──────────────────────────┘│
│                                       │                            │
│  Ara toplam:           ₺747          │  ┌─ Selected: Nakit ────┐ │
│  İskonto:              -₺47          │  │ Tutar: [₺ 700,00]    │ │
│  KDV (%20):            ₺140          │  │ Para üstü: ₺0         │ │
│  ─────────────────────────────       │  │                       │ │
│  TOPLAM:               ₺700          │  │ [Hızlı: ₺100 ₺200    │ │
│                                       │  │         ₺500 ₺700]    │ │
│                                       │  │                       │ │
│                                       │  │ [Devam et (Enter)]    │ │
│                                       │  └──────────────────────┘ │
│                                       │                            │
│                                       │  ┌──────────────────────┐ │
│                                       │  │ [F12 TAMAMLA]        │ │
│                                       │  │  (disabled)          │ │
│                                       │  └──────────────────────┘ │
└──────────────────────────────────────┴───────────────────────────┘
```

### Customer account sub-state

```
┌─ Tender workspace ──────────────────────────────────────────────┐
│  Müşteri Hesabına Yaz                                            │
│  ────────────────────                                            │
│  Müşteri: Ahmet Yılmaz                                            │
│                                                                   │
│  Mevcut bakiye:          ₺450 (borç)                             │
│  Kredi limiti:           ₺1.000                                   │
│  Müsait kredi:           ₺550                                     │
│                                                                   │
│  Tutar: [₺ 700,00]                                                │
│                                                                   │
│  ⚠ Kredi limitini aşacak. Yönetici onayı gerekli.                │
│  Yönetici PIN: [______]                                           │
│  Sebep: [Tanıdık müşteri ▾]                                       │
│                                                                   │
│  [Devam et (Enter)]                                               │
└───────────────────────────────────────────────────────────────────┘
```

### Multi-tender state

```
┌─ Tender workspace ──────────────────────────────────────────────┐
│  Kalan: ₺200,00                                                   │
│                                                                   │
│  ┌─ APPROVED tenders ─────────────────────────────────────────┐ │
│  │ ✓ Nakit            ₺500,00       [İptal (manager req.)]    │ │
│  └────────────────────────────────────────────────────────────┘ │
│                                                                   │
│  Yeni ödeme:                                                      │
│  [1 Nakit] [2 Kart] [3 Hesap]                                    │
│                                                                   │
│  [F12 TAMAMLA] (still ₺200 remaining)                            │
└───────────────────────────────────────────────────────────────────┘
```

## Audit events

- `sale_proceeded_to_payment`
- `sale_reverted_to_draft`
- `sale_reverted_with_approved_tenders`
- `sale_voided`
- `sale_completed`
- `tender_dispatched`
- `tender_approved`
- `tender_declined`
- `tender_timeout`
- `tender_cancelled_by_cashier`
- `tender_cancelled_by_manager`
- `tender_refunded` (after APPROVED)
- `credit_limit_exceeded_with_override`
- `cash_drawer_opened` (with reason: SALE_COMPLETE | MANUAL_NO_SALE | CHANGE_GIVEN | REFUND)
- `sale_reconciliation_required`

## Security / fraud notes

- Cash drawer opens ONLY at Sale.complete success or manual via F8 (audit logged)
- Card tender APPROVED only via terminal callback or manager override path
- Customer change while AWAITING_PAYMENT not allowed (locked mutation)
- Idempotency key + DB UNIQUE prevents double-complete

## Implementation notes

- All money math via Dinero.js; client/server mismatch > ₺0.01 → silent toast + Sentry
- Idempotency key: useIdempotencyKey hook (Zustand), cleared on success
- Card terminal MVP: StubTerminalAdapter (always APPROVED after 2s for demos)
- Real terminal adapters v1.1+ (Ingenico, Verifone)
- Outbox events emitted from same atomic TX as state change
