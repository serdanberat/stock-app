# ADR 001 — Modular Monolith over Microservices

> **Status:** Accepted
> **Date:** 2026-05-15
> **Deciders:** Product owner, architect

## Context

We are building a multi-tenant retail ERP/POS for clothing, boutique, jewellery and accessory stores. Initial deployment is SaaS; on-premise deployment will follow. The team is small and time-to-market matters; the product must be sellable to real stores, not a demo.

## Decision

We will build a **modular monolith** with explicit bounded contexts (11 contexts identified in Phase 2A). The system runs as a single deployable backend service backed by a single PostgreSQL database. Contexts are isolated by code structure (separate modules, separate schemas) and by interface (no cross-context table JOINs), not by deployment.

## Rationale

A monolith fits the operational scale: a single store completes a sale in 5 seconds; one PostgreSQL instance handles thousands of concurrent stores comfortably. Most of the operational complexity in retail ERP comes from **domain modelling** (stock, money, multi-currency, multi-store, audit), not from distribution. Distributed systems would add complexity (network failure modes, distributed transactions, eventual consistency tax) without a corresponding scale-out benefit at this stage.

Concretely:
- **Atomic transactions across contexts** (Sale → Inventory → CashRegister → Financial) are the dominant requirement for POS. A monolith makes this trivial. A microservice architecture would force sagas, compensating transactions, and a much larger surface for partial failure.
- **A single source of truth** (PostgreSQL with RLS) keeps multi-tenant data isolation simple.
- **Deployment is simpler**, on-premise installations are realistic, and infrastructure cost is minimal.
- **Refactoring is cheaper** in a monolith. Bounded contexts give us optionality to extract services later if a specific context becomes a scale bottleneck.

## Modularity discipline

To preserve the option to extract services later, the monolith enforces:
- **No cross-context JOINs.** Each context's tables live in a logical module; only the owning module reads/writes them.
- **Service contracts.** Cross-context communication goes through service interfaces (`InventoryService`, `PricingService`, `FinancialService`, etc.) or domain events through the outbox.
- **Stable APIs.** A context's external contract is more stable than its internal tables.
- **One writer per entity.** `stock_movements` only via `InventoryService.recordMovement()`; `account_movements` only via `FinancialService.appendJournal()`.

## Consequences

**Positive:**
- Faster delivery; less infrastructure to operate.
- Atomic sale completion is straightforward (Sale + stock + cash + account in one DB transaction).
- Strong consistency where it matters; eventual consistency only for reporting and audit.
- On-premise deployment is realistic for tenants who want it.
- Bounded contexts preserve future extractability.

**Negative:**
- Vertical scaling is the only short-term option. Acceptable: PostgreSQL handles millions of writes per day comfortably and partitioning (see ADR 003) is on the roadmap.
- Discipline is required to prevent inter-context coupling at the DB level. Mitigated by code-review rules and separate schemas/modules.
- A truly large enterprise tenant (multi-region, very high write throughput) might eventually require extraction of a hot context (most likely Reporting or Inventory). The boundaries are designed to make this feasible.

## Alternatives Considered

- **Microservices from day one** — rejected. Too much undifferentiated heavy lifting (service mesh, distributed tracing, distributed transactions, ops complexity) for the value delivered.
- **Service-per-context with shared DB** — rejected. Hybrid worst-of-both: distributed deployment without distributed-data isolation.
- **Event-sourced from day one** — rejected for MVP. The append-only ledgers (`stock_movements`, `account_movements`) plus outbox give us the durability and audit benefits of event sourcing where they matter, without committing the entire model to it.

## Revisit Criteria

We will revisit this decision when one of the following is true:
- A single context (most likely Reporting) is causing observable contention on the main DB.
- A specific tenant requires geographically distributed deployment.
- Team size and operational maturity make microservices' operational cost acceptable.
