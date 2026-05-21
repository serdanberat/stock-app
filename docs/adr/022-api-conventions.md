# ADR-022 — API Conventions

> **Status:** Accepted
> **Date:** 2026-05-21
> **Phase:** 5 (Endpoint Catalogue + OpenAPI Skeleton)

## Context

The system exposes ~174 endpoints across 10 modules. Without explicit conventions:

- URL patterns drift (some `/resource/delete`, some `DELETE /resource`, some `/resource/deactivate`)
- Idempotency requirements become unclear (which endpoints need keys?)
- Error responses inconsistent (some flat `{ error: "x" }`, some Spring default Problem)
- Correlation tracing breaks (no header standard)
- Pagination shape varies per developer

This ADR locks the conventions for all current and future endpoints. Phase 7 implementation references this ADR; deviations require new ADR.

## Decision

Adopt the following conventions, documented in detail at `docs/api/05-api-conventions.md`:

### 1. URL pattern

- `GET /resource` for simple lists (≤3 filter params)
- `POST /resource/search` for complex search (multi-field filters, body-encoded)
- `GET /resource/{id}` for detail
- `POST /resource` for create
- `PATCH /resource/{id}` for field mutation
- `POST /resource/{id}/{action}` for lifecycle transition

### 2. NO hard delete endpoints

All "delete" operations expressed as state transitions: `deactivate`, `archive`, `cancel`, `abandon`. ArchUnit/lint enforces no `@DeleteMapping`.

### 3. PATCH vs Action

PATCH for field updates; POST action for state transitions. Explicit split, no overlap.

### 4. Idempotency

`X-Idempotency-Key` (UUIDv4) required for all POST create + POST action endpoints. NOT required for PATCH or POST /search. 7-day retention.

### 5. Correlation-Id

`X-Correlation-Id` header. Client may send; server generates if absent; always echoed in response. Bridges to domain-level `correlation_id` (ADR-020).

### 6. Error format

RFC 7807 `application/problem+json`. Fields: `type` (stable URI), `title`, `status`, `detail`, `instance`, `errorCode` (namespaced enum), `context` (structured runtime data), `correlationId`.

`errorCode` uses module-namespaced prefixes: `INV_`, `SALE_`, `FIN_`, `PUR_`, `CASH_`, `CAT_`, `PRICE_`, `AUTH_`, `USER_`, `COMMON_`, etc.

`type` URLs are stable (NOT runtime-generated). Catalog: `https://api.stockapp.example/problems/<error-code-slug>`.

### 7. Pagination

Consistent shape:
- Request: `page` (1-indexed), `page_size` (default 20, max 100), `sort`
- Response: `data[]` + `pagination { page, page_size, total_items?, total_pages?, has_next, has_prev }`
- `total_items` may be `null` for performance-critical endpoints (rare in MVP)

### 8. OpenAPI 3.1.0

JSON Schema 2020-12 compatible. Spring Boot 3+ + springdoc-openapi at Phase 7 generates spec from controllers.

### 9. Custom OpenAPI extensions

| Extension | Purpose |
|---|---|
| `x-permission` | Required permission code |
| `x-idempotent` | true/false |
| `x-screen-ref` | Phase 3 screen reference |
| `x-aggregate` | Owning aggregate (traceability) |

### 10. Async operations

`POST /resource/{id}/export` returns 202 with `ExportJobResponse` (job_id, poll_url). Client polls `GET /jobs/{jobId}` for status.

### 11. Manager PIN override flow

1. Client `POST /auth/manager-pin-verify` → receives `override_token` (60s TTL, single-use)
2. Client includes `override_token` in subsequent request body
3. Server validates, allows operation, consumes token

### 12. Authentication

JWT Bearer (`Authorization: Bearer <token>`) on all endpoints except `/auth/login`, `/auth/refresh`. Per ADR-013 (HS256, 15min access, 7d refresh).

### 13. API versioning

MVP: no version prefix. Additive changes don't bump version. Breaking changes MAY introduce `/v2/` prefix at v1.1+ with 6-month deprecation.

## Consequences

### Positive

- **Predictable**: developers building new endpoints follow templates
- **Consistent error handling**: frontend has one switch on `errorCode`
- **Audit-traceable**: every request has correlation_id from edge to outbox event
- **Idempotency-safe**: double-clicks and retries never double-apply
- **Documented**: OpenAPI generation auto-validates conventions match controllers
- **Refactorable**: state-transition endpoints make audit logs readable ("user X called dispatchTransfer at Y" vs "PATCH /transfers/X")
- **Defense-in-depth**: no DELETE endpoints means lower fraud/mistake surface

### Negative

- **More endpoints**: PATCH-vs-Action split increased endpoint count from ~120 estimate to ~174 actual. Each endpoint is simpler though.
- **Verbose URL paths**: `/finance/purchase-invoices/{id}/commit` longer than `PUT /purchase-invoices/{id}`. Trade-off accepted for clarity.
- **Error type URLs must stay stable**: changing `errorCode` requires new ADR or careful deprecation.
- **Initial OpenAPI generation requires springdoc-openapi setup at Phase 7**

### Neutral

- OpenAPI tooling (codegen, mock servers, documentation) works with conventional schema; no ecosystem friction.
- RFC 7807 standard well-supported across languages.

## Rules for adding new endpoints

Every new endpoint requires:

1. Entry in `docs/api/05-endpoint-catalogue.md` table
2. Method + path follows URL pattern conventions
3. Permission code declared
4. Idempotency requirement determined per rule
5. Error codes used follow namespacing convention; new codes added to catalog
6. OpenAPI path entry with `x-permission`, `x-idempotent`, `x-screen-ref` extensions
7. (Phase 7) Controller method annotation matches OpenAPI spec; springdoc verifies

## Anti-patterns this ADR rules out

- `DELETE /resource/{id}` for hard delete
- Inconsistent error shapes per endpoint
- Missing `X-Idempotency-Key` validation on POST create
- Flat error codes without module prefix
- Pagination shape variations between endpoints
- Skipping correlation_id propagation

## Related

- ADR-005 Outbox pattern
- ADR-008 Idempotency key strategy
- ADR-013 JWT HS256 + BCrypt 12
- ADR-020 Correlation ID Pattern
- ADR-021 Module Dependency Matrix
- Phase 5 Endpoint Catalogue (`docs/api/05-endpoint-catalogue.md`)
- Phase 5 API Conventions (`docs/api/05-api-conventions.md`)
- Phase 5 OpenAPI Skeleton (`docs/api/openapi.yaml`)
