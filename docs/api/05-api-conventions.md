# API Conventions

> **Status:** Locked (Phase 5)
> **Last updated:** 2026-05-21

This document defines the conventions all API endpoints follow. Every endpoint in `05-endpoint-catalogue.md` and `openapi.yaml` references these rules.

---

## URL pattern conventions

### Resource paths

| Pattern | Use case | Example |
|---|---|---|
| `GET /resource` | Simple list (≤3 filter params, no complex query) | `GET /catalog/brands`, `GET /stores` |
| `POST /resource/search` | Complex search (multi-field filters, body-encoded criteria) | `POST /catalog/products/search`, `POST /inventory/stock-balances/search` |
| `GET /resource/{id}` | Detail | `GET /sales/{id}` |
| `POST /resource` | Create | `POST /finance/purchase-invoices` |
| `PATCH /resource/{id}` | Partial field update | `PATCH /catalog/products/{id}` |
| `POST /resource/{id}/{action}` | Lifecycle transition | `POST /purchase-invoices/{id}/commit`, `POST /transfers/{id}/dispatch` |

### Rule: PATCH vs Action endpoint

| Operation type | HTTP method |
|---|---|
| Field mutation (display_name, note, settings) | `PATCH` |
| Lifecycle state transition (DRAFT → COMMITTED, dispatch, finalize, complete, close, cancel) | `POST /{id}/{action}` |

Examples:

```
PATCH /catalog/products/{id}        # update name, code, description, etc.
PATCH /finance/purchase-invoices/{id} # edit DRAFT fields

POST /finance/purchase-invoices/{id}/commit         # DRAFT → COMMITTED
POST /inventory/transfers/{id}/dispatch             # DRAFT → DISPATCHED
POST /inventory/counts/{id}/finalize                # IN_PROGRESS → FINALIZED
POST /pos/sales/{id}/complete                       # AWAITING_PAYMENT → COMPLETED
POST /cash-register/sessions/{id}/close             # OPEN → CLOSED
```

This split forces clarity: "is this a state change or a field edit?" The state-change has its own endpoint with idempotency and audit semantics.

### Rule: Search via POST when filters are complex

`GET` for simple lists. `POST /search` for:
- Multi-field filters with optional combinations
- Date ranges
- Free-text query alongside structured filters
- Sort + filter + pagination combination

Reason: URL length limits + URL-encoded filter readability + `GET` doesn't carry a body in REST semantics.

### Rule: NO hard delete endpoints

**Hard delete endpoints are FORBIDDEN in MVP API surface.**

Reason: in a system with audit trails, references, and event correlation, hard delete creates dangling references and undoable mistakes. Every "delete" in business sense is actually a state transition:

| What user calls "delete" | Actual operation |
|---|---|
| Delete a customer | `POST /parties/{id}/deactivate` |
| Delete a product | `POST /catalog/products/{id}/archive` |
| Delete a draft sale | `POST /pos/sales/{id}/cancel` |
| Delete a user | `POST /admin/users/{id}/deactivate` |
| Delete a price list | `POST /pricing/lists/{id}/archive` |

DRAFT-state resources that never affected stock/finance MAY support hard delete internally (e.g., DRAFT purchase invoice abandoned before commit), but the API expresses this as `POST /resource/{id}/abandon` for consistency.

ArchUnit/lint can enforce: no `@DeleteMapping` annotation in any controller.

---

## Standard headers

### Request headers

| Header | Required | Purpose |
|---|---|---|
| `Authorization: Bearer <jwt>` | Yes (except `/auth/login`, `/auth/refresh`) | JWT bearer token per ADR-013 |
| `Content-Type: application/json` | For POST/PATCH | Standard |
| `X-Idempotency-Key: <uuid>` | Yes for write-consequential endpoints (see Idempotency section) | Client-generated UUID; 7-day retention |
| `X-Correlation-Id: <uuid>` | Optional (client) / Yes (auto-generated server) | Request trace correlation; see ADR-020 + Correlation-Id section below |

### Response headers

| Header | When | Purpose |
|---|---|---|
| `Content-Type: application/json` | Success responses | Default |
| `Content-Type: application/problem+json` | Error responses | RFC 7807 |
| `X-Correlation-Id: <uuid>` | Always | Same as request (or server-generated if missing); echoed for client logging |
| `Location: /resource/{id}` | After successful POST create | New resource location |

---

## Correlation-Id header

### Header

```
X-Correlation-Id: <uuid>
```

### Semantics

Per ADR-020 Correlation ID Pattern. The HTTP-level Correlation-Id maps to the domain-level `correlation_id` of the operation if one is created.

### Rules

1. **Client may send** `X-Correlation-Id` to tie multiple requests into a logical operation (e.g. a multi-step UI flow).
2. **If client does not send**, server generates one.
3. **Server always echoes** the value in response headers.
4. **Server logs** Correlation-Id with every log line for the request (via MDC).
5. **Outbox events** generated during the request carry this Correlation-Id.
6. **Audit log entries** carry this Correlation-Id.
7. **Sentry / observability** errors are tagged with Correlation-Id.

### Phase 7 implementation

- Spring filter: `CorrelationIdFilter` extracts/generates and sets `MDC.put("correlationId", ...)`
- `CorrelationIdHolder` ThreadLocal (shared kernel) propagates to outbox event payloads
- Every log line includes correlation_id via Logback pattern

---

## Idempotency

### Header

```
X-Idempotency-Key: <client-generated-uuid>
```

UUIDv4 format. Server validates format and returns 400 if malformed.

### When required vs not

| Endpoint type | Idempotency required? | Why |
|---|---|---|
| `POST` create | YES | Network retry, double-click |
| `POST {id}/{action}` lifecycle transition | YES | Idempotent commit/dispatch/finalize/complete prevents double-application |
| `POST {id}/{action}` query-like (e.g. force-close) | YES | Same reasoning |
| `PATCH` field update | NO | Last-writer-wins is acceptable for field updates |
| `GET` | N/A | Naturally idempotent |
| `POST /search` | NO | Read operation despite POST method |
| `POST /export` | YES | Async work request; dedup |

### Server behavior

- First request with key X: process normally, store `(tenant_id, key, response_payload)` in `idempotency_keys` table
- Subsequent request with same key X within 7 days: return cached response with same status code
- After 7 days: key expires; key reuse treated as new request

### Retention

7 days per ADR-008. Cleanup via scheduled job (Phase 6.G).

### Client guidance

UUIDv4 per request attempt. Same UUID on retry (network timeout, etc.). New UUID for genuinely new requests.

---

## Pagination

### Request

For `POST /search` endpoints, pagination is in the request body:

```json
{
  "page": 1,
  "page_size": 20,
  "sort": "-created_at,name",
  "filters": { ... }
}
```

For `GET /resource` endpoints, query parameters:

```
GET /catalog/brands?page=1&page_size=20&sort=name
```

### Defaults and limits

| Field | Default | Max |
|---|---|---|
| `page` | 1 | (1-indexed) |
| `page_size` | 20 | 100 |
| `sort` | endpoint-specific | comma-separated; `-` prefix = descending |

### Response shape

```json
{
  "data": [ /* array of resource objects */ ],
  "pagination": {
    "page": 1,
    "page_size": 20,
    "total_items": 247,
    "total_pages": 13,
    "has_next": true,
    "has_prev": false
  }
}
```

### Performance note: `total_items` may be omitted

Some reporting endpoints (large date ranges, complex joins) may omit `total_items` and `total_pages` for performance. Response shape becomes:

```json
{
  "data": [ ... ],
  "pagination": {
    "page": 1,
    "page_size": 20,
    "has_next": true,
    "has_prev": false,
    "total_items": null,
    "total_pages": null
  }
}
```

Clients use `has_next` for pagination UI when total unknown.

MVP: full count acceptable for all endpoints. v1.1+ may relax for performance-critical reports.

---

## Error responses (RFC 7807)

### Content type

`Content-Type: application/problem+json`

### Schema

```json
{
  "type": "https://api.stockapp.example/problems/insufficient-stock",
  "title": "Insufficient Stock",
  "status": 422,
  "detail": "Variant T-100-BLK-S has 2 available; requested 5",
  "instance": "/pos/sales/abc-123/complete",
  "errorCode": "INV_INSUFFICIENT_STOCK",
  "context": {
    "variant_id": "f47ac10b-58cc-4372-a567-0e02b2c3d479",
    "available": 2,
    "requested": 5
  },
  "correlationId": "8b3a-..."
}
```

### Field rules

| Field | Source | Stability |
|---|---|---|
| `type` | Static catalog URL (NOT runtime-generated) | Stable; URLs survive across versions |
| `title` | Human-readable short description | Stable per `type` |
| `status` | HTTP status code | Stable per `type` |
| `detail` | Runtime instance description | May contain dynamic values |
| `instance` | Request path | Per-request |
| `errorCode` | Stable enum from shared kernel | Stable; clients switch on this |
| `context` | Structured runtime data | Schema may evolve |
| `correlationId` | Same as response `X-Correlation-Id` header | Per-request |

### `type` URL stability

The `type` URL is a stable identifier. Clients (frontend) link to documentation via the `type` URL or check it programmatically.

Catalog: `https://api.stockapp.example/problems/<error-code-slug>`

Each entry in the error catalog (next section) has a corresponding `type` URL. New problems require:
1. New entry in error catalog
2. New `type` URL added
3. Frontend documentation links update

### `errorCode` namespace convention

ErrorCodes use module prefixes:

| Prefix | Module |
|---|---|
| `AUTH_` | identity authentication |
| `USER_` | identity user admin |
| `TENANT_` | identity tenant |
| `STORE_` | identity stores |
| `CAT_` | catalog |
| `PRICE_` | pricing |
| `INV_` | inventory |
| `SALE_` | sales |
| `RETURN_` | sales (returns sub-package) |
| `PUR_` | purchasing |
| `FIN_` | finance |
| `CASH_` | cashregister |
| `REPORT_` | reporting |
| `COMMON_` | shared/cross-cutting |

Examples:

```
INV_INSUFFICIENT_STOCK
SALE_ALREADY_COMPLETED
SALE_DRAFT_REQUIRED
FIN_CREDIT_LIMIT_EXCEEDED
FIN_STORE_CREDIT_INSUFFICIENT
PUR_INVOICE_NUMBER_DUPLICATE
PUR_INVOICE_NOT_COMMITTABLE
CASH_SESSION_ALREADY_OPEN
CASH_VARIANCE_REASON_REQUIRED
CAT_VARIANT_ATTRIBUTES_LOCKED
PRICE_BELOW_COST_REASON_REQUIRED
AUTH_INVALID_CREDENTIALS
AUTH_MANAGER_PIN_LOCKED
COMMON_TENANT_ISOLATION_VIOLATION
COMMON_IDEMPOTENCY_KEY_INVALID
COMMON_VALIDATION_FAILED
```

This prevents conflicts when modules grow independently. ErrorCode lives in `io.stockapp.shared.error.ErrorCode` enum.

---

## Error catalog (MVP — extended at Phase 7)

Stable `type` URLs and standard HTTP status. Frontend should switch on `errorCode`, not `status`.

### Common (shared, cross-cutting)

| errorCode | HTTP | type URL slug | When |
|---|---|---|---|
| `COMMON_VALIDATION_FAILED` | 400 | validation-failed | Field validation (Bean Validation) failed |
| `COMMON_IDEMPOTENCY_KEY_INVALID` | 400 | idempotency-key-invalid | Malformed or missing X-Idempotency-Key |
| `COMMON_IDEMPOTENCY_KEY_REPLAYED` | 200 (cached) | (no error; cached response served) | Same key, returning prior response |
| `COMMON_UNAUTHORIZED` | 401 | unauthorized | Missing/expired JWT |
| `COMMON_FORBIDDEN` | 403 | forbidden | Insufficient permissions for action |
| `COMMON_NOT_FOUND` | 404 | not-found | Resource not found |
| `COMMON_CONFLICT` | 409 | conflict | Optimistic concurrency conflict, version mismatch |
| `COMMON_RATE_LIMITED` | 429 | rate-limited | Too many requests |
| `COMMON_INTERNAL_ERROR` | 500 | internal-error | Unexpected server error |
| `COMMON_TENANT_ISOLATION_VIOLATION` | 500 | tenant-isolation-violation | Should never reach client; alerting trigger |

### Identity / Auth

| errorCode | HTTP | When |
|---|---|---|
| `AUTH_INVALID_CREDENTIALS` | 401 | Wrong username/password |
| `AUTH_TOKEN_EXPIRED` | 401 | JWT expired (clients should refresh) |
| `AUTH_TOKEN_INVALID` | 401 | Malformed/forged JWT |
| `AUTH_MANAGER_PIN_REQUIRED` | 403 | Operation needs manager PIN override |
| `AUTH_MANAGER_PIN_INVALID` | 401 | Wrong PIN |
| `AUTH_MANAGER_PIN_LOCKED` | 423 | 3-fail lockout active |
| `USER_LAST_SUPER_ADMIN` | 422 | Cannot deactivate last SUPER_ADMIN |
| `USER_SELF_DEACTIVATE` | 403 | Cannot deactivate self |
| `USER_EMAIL_TAKEN` | 409 | Email already in use |
| `TENANT_DANGEROUS_FLAG_CONFIRMATION_INVALID` | 400 | Typed confirmation phrase wrong |

### Catalog

| errorCode | HTTP | When |
|---|---|---|
| `CAT_VARIANT_NOT_FOUND` | 404 | Variant lookup miss |
| `CAT_BARCODE_ALREADY_EXISTS` | 409 | Duplicate barcode allocation (should be impossible after Phase 6.B sequence allocator) |
| `CAT_VARIANT_ATTRIBUTES_LOCKED` | 422 | Attempt to mutate attributes after first sale |
| `CAT_SYSTEM_ATTRIBUTE_IMMUTABLE` | 422 | Attempt to mutate system_key on seed attribute |
| `CAT_PRODUCT_NOT_PUBLISHED` | 422 | Operation requires PUBLISHED product |

### Pricing

| errorCode | HTTP | When |
|---|---|---|
| `PRICE_NOT_FOUND` | 404 | No active price for variant+store |
| `PRICE_BELOW_COST_REASON_REQUIRED` | 422 | Setting price below WAC without reason |
| `PRICE_LIST_NOT_ACTIVE` | 422 | Operation requires ACTIVE price list |

### Inventory

| errorCode | HTTP | When |
|---|---|---|
| `INV_INSUFFICIENT_STOCK` | 422 | Operation would push balance < 0 and tenant doesn't allow negative |
| `INV_STORE_CLOSED` | 422 | Target store is CLOSED |
| `INV_TRANSFER_SAME_STORE` | 422 | Source == target |
| `INV_TRANSFER_NOT_DISPATCHABLE` | 422 | State conflict |
| `INV_TRANSFER_NOT_RECEIVABLE` | 422 | State conflict |
| `INV_TRANSFER_DISCREPANCY_REASON_REQUIRED` | 422 | Receive < dispatched without reason |
| `INV_COUNT_SESSION_NOT_FINALIZABLE` | 422 | State conflict |
| `INV_ADJUSTMENT_LARGE_CONFIRMATION_REQUIRED` | 422 | Large adjustment without second confirm |
| `INV_ADJUSTMENT_OTHER_REASON_REQUIRED` | 422 | OTHER reason without free_text |

### Sales (POS + Returns)

| errorCode | HTTP | When |
|---|---|---|
| `SALE_NOT_FOUND` | 404 | Sale lookup miss |
| `SALE_NOT_COMPLETABLE` | 422 | State conflict |
| `SALE_ALREADY_COMPLETED` | 422 | Idempotent attempt on completed sale |
| `SALE_LINE_PRICE_REQUIRED` | 422 | Line missing resolved price (broken cache) |
| `SALE_DISCOUNT_THRESHOLD_REASON_REQUIRED` | 422 | Discount % over threshold without reason |
| `SALE_DISCOUNT_MUTEX_VIOLATION` | 422 | Both line and cart discount applied |
| `SALE_DISCOUNT_LIMIT_EXCEEDED` | 422 | Discount % > cashier limit without manager override |
| `RETURN_OUTSIDE_WINDOW` | 422 | Sale outside `return_window_days` |
| `RETURN_QUANTITY_EXCEEDS_REMAINING` | 422 | Returning more than remaining |
| `RETURN_REFUND_TENDER_NOT_ALLOWED` | 422 | WITHOUT_REFERENCE refund tries CASH/CARD_REFUND |
| `RETURN_WITHOUT_REFERENCE_REASON_REQUIRED` | 422 | Missing manager PIN + reason + note |
| `RETURN_EXCHANGE_TENDER_MISMATCH` | 422 | Settlement delta tender invalid |

### Purchasing

| errorCode | HTTP | When |
|---|---|---|
| `PUR_INVOICE_NOT_FOUND` | 404 | Lookup miss |
| `PUR_INVOICE_NOT_COMMITTABLE` | 422 | State conflict |
| `PUR_INVOICE_NUMBER_DUPLICATE` | 409 | (tenant, supplier, number) already exists |
| `PUR_INVOICE_REVERSE_NOT_ALLOWED` | 422 | Status not COMMITTED |
| `PUR_INVOICE_LINE_INVALID` | 400 | Negative qty/cost or missing fields |

### Finance

| errorCode | HTTP | When |
|---|---|---|
| `FIN_ACCOUNT_NOT_FOUND` | 404 | Party has no AccountProfile |
| `FIN_CREDIT_LIMIT_EXCEEDED` | 422 | CUSTOMER_ACCOUNT tender exceeds limit |
| `FIN_STORE_CREDIT_INSUFFICIENT` | 422 | STORE_CREDIT_REDEMPTION exceeds available |
| `FIN_BANK_TRANSFER_REF_DUPLICATE` | 409 | bank_transfer_reference UNIQUE conflict |
| `FIN_BANK_TRANSFER_REF_REQUIRED` | 400 | BANK_TRANSFER tender without reference |
| `FIN_PAYMENT_TENDER_NOT_ALLOWED` | 422 | Tender invalid for direction |
| `FIN_OVERPAYMENT_WARNING` | 200 (warning header) | Amount > current debt (not blocking) |

### Cash Register

| errorCode | HTTP | When |
|---|---|---|
| `CASH_SESSION_ALREADY_OPEN` | 409 | One OPEN per (store, register) invariant |
| `CASH_SESSION_NOT_OPEN` | 422 | Cash operation without OPEN session |
| `CASH_SESSION_NOT_CLOSEABLE` | 422 | Pending uncompleted sales |
| `CASH_VARIANCE_REASON_REQUIRED` | 422 | Variance > tolerance without reason |
| `CASH_LARGE_VARIANCE_MANAGER_PIN_REQUIRED` | 422 | Variance > large_threshold without PIN |
| `CASH_FORCE_CLOSE_NOTE_TOO_SHORT` | 400 | Reconciliation_note < 20 chars |
| `CASH_ORPHAN_SESSION_EXISTS` | 409 | Open attempt while orphan present |

### Reporting

| errorCode | HTTP | When |
|---|---|---|
| `REPORT_EXPORT_QUEUED` | 202 | CSV export queued; not an error but uses Problem schema for consistency |
| `REPORT_PERIOD_INVALID` | 400 | Bad date range |

---

## Authentication / Authorization

### Authentication

- All endpoints require `Authorization: Bearer <jwt>` EXCEPT:
  - `POST /auth/login`
  - `POST /auth/refresh`
- JWT issuer/algorithm/expiry per ADR-013 (HS256, 15min access, 7d refresh)
- Token validation failure → `401 AUTH_TOKEN_EXPIRED` or `AUTH_TOKEN_INVALID`

### Authorization

- Each endpoint declares required permission code in OpenAPI `x-permission` extension
- Spring Security checks at controller method level
- Missing permission → `403 COMMON_FORBIDDEN` with `context.required_permission`

### Manager PIN override (3.A.4 + ADR pattern)

For operations requiring manager PIN:

1. Client first POSTs to `/auth/manager-pin-verify` with `{ pin }`
2. Server validates, returns `{ override_token, expires_at }` (60s TTL)
3. Client includes `override_token` in subsequent request body
4. Server validates token, allows operation, single-use consumption

Override token errors:
- `AUTH_MANAGER_PIN_REQUIRED` (no token provided)
- `AUTH_MANAGER_PIN_INVALID` (wrong PIN)
- `AUTH_MANAGER_PIN_LOCKED` (3-fail lockout)
- `AUTH_OVERRIDE_TOKEN_EXPIRED` (token expired or consumed)

---

## API versioning

MVP: no version prefix in URL. Single version (v1) implicit.

Breaking changes plan:
- Additive changes (new endpoints, new optional fields): compatible, no version bump
- Breaking changes (removed fields, changed semantics): MAY introduce v2 prefix `(/v2/resource)` when needed; v1 deprecation policy 6 months minimum

OpenAPI `info.version` reflects build version; not URL path.

---

## Response status conventions

| Status | When |
|---|---|
| 200 OK | GET, PATCH, idempotent POST replays |
| 201 Created | POST create with new resource (includes `Location` header) |
| 202 Accepted | Async operations (CSV export queued, document generation queued) |
| 204 No Content | DELETE (only internal/DRAFT), some PATCH with no body |
| 400 Bad Request | Validation, malformed body |
| 401 Unauthorized | Auth missing/invalid |
| 403 Forbidden | Insufficient permission |
| 404 Not Found | Resource doesn't exist |
| 409 Conflict | Uniqueness conflict, optimistic concurrency, duplicate idempotency-not-replay |
| 422 Unprocessable Entity | Domain rule violation (state, business invariant) |
| 423 Locked | Manager PIN lockout |
| 429 Too Many Requests | Rate limited |
| 500 Internal Server Error | Unhandled |

**Convention**: 422 for domain rule violation; 400 for malformed input. Distinct.

---

## Request validation

Bean Validation (Jakarta) annotations on request DTOs:
- `@NotNull`, `@NotBlank`, `@Size(min, max)`, `@Pattern`, `@Email`, etc.
- `@Valid` propagation for nested DTOs

Validation failure → `400 COMMON_VALIDATION_FAILED` with `context.field_errors`:

```json
{
  "errorCode": "COMMON_VALIDATION_FAILED",
  "context": {
    "field_errors": [
      { "field": "email", "message": "must be a valid email" },
      { "field": "amount", "message": "must be > 0" }
    ]
  }
}
```

---

## Async operation responses

CSV exports and document generation queue work for the document worker (Phase 6.F).

Pattern: `POST /resource/{id}/export` returns:

```json
{
  "status": "QUEUED",
  "job_id": "exp-abc-123",
  "poll_url": "/jobs/exp-abc-123",
  "expected_completion_seconds": 30
}
```

Client polls `GET /jobs/{job_id}` for status: QUEUED / RUNNING / COMPLETED / FAILED, with download URL when COMPLETED.

---

## Rate limiting

MVP: no rate limiting per ADR-? (open). Phase 7 may add basic rate limit for `/auth/login` (5/minute per IP) to mitigate brute force.

v1.1+: per-tenant rate limits for high-volume endpoints.

---

## OpenAPI extensions used

| Extension | Purpose |
|---|---|
| `x-permission` | Required permission code for the endpoint |
| `x-idempotent` | Whether endpoint requires X-Idempotency-Key |
| `x-screen-ref` | Reference to Phase 3 screen spec (e.g., "3.A.5") |
| `x-aggregate` | Owning aggregate (for traceability) |

Example:

```yaml
/finance/purchase-invoices/{id}/commit:
  post:
    operationId: commitPurchaseInvoice
    x-permission: purchasing.invoices.commit
    x-idempotent: true
    x-screen-ref: "3.D.2"
    x-aggregate: PurchaseInvoice
    ...
```

These extensions appear in generated docs but don't affect OpenAPI tooling.
