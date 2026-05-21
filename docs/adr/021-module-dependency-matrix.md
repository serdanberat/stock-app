# ADR-021 — Module Dependency Matrix as Engineering Contract

> **Status:** Accepted
> **Date:** 2026-05-21
> **Phase:** 4 (Module Contracts)

## Context

Modular monolith architecture requires explicit module boundaries to prevent erosion into spaghetti monolith over time. The most common failure modes in modular monoliths are:

1. **Direct illegal dependency**: developer imports a class from forbidden module ("just this once")
2. **Hidden transitive orchestration**: module A calls B which calls C; A indirectly mutates C
3. **Bidirectional coupling**: catalog accidentally depending on pricing because of a "convenience" query
4. **Junk-drawer shared kernel**: shared module accumulates services, repositories, entities
5. **Repository injection in read-only consumers**: reporting injects inventory repositories instead of going through query services

Without explicit, enforced contracts, these failures accumulate gradually under deadline pressure. By month 18, the modular monolith is monolith in name only.

Two artifacts can prevent this:

- **Human-readable dependency matrix**: intent + code-review reference
- **ArchUnit rules**: machine-enforced; fails CI on violation

Either alone is insufficient. Matrix without ArchUnit erodes slowly. ArchUnit without matrix produces "why does this rule exist?" confusion at PR time; rules get suppressed.

## Decision

Adopt the **Phase 4 Module Dependency Matrix** as the central engineering contract for the modular monolith. The matrix is:

1. **Human-readable** (in `docs/architecture/04-module-contracts.md`)
2. **Machine-enforced** (via ArchUnit rules in `tests/architecture/`)
3. **Versioned with the code** (changes require PR + ADR justification)

### Matrix structure

10 modules × 10 modules grid. Each cell carries one of:

- `—` — self
- `Q` — read-only query dependency allowed
- `W` — synchronous write dependency allowed (same TX)
- `Q+W` — both query and write allowed
- `✗` — forbidden (ArchUnit-enforced)

### Cross-module write rule

A `W` cell means the depending module's application services may call the depended-upon module's `application.command` package. Same TX (REQUIRED propagation).

### Cross-module orchestration rule

**Cross-module writes must be orchestrated at the ORIGINATING module's application service.** Nested orchestration through intermediate modules is forbidden. ArchUnit Kategori C rule enforces this.

### Sub-package convention

Each module follows canonical structure:

```
io.stockapp.<module>/
├── api/
├── application/{command,query,orchestrator}/
├── domain/{<aggregate>,event}/
├── eventconsumer/                 # optional
└── infrastructure/{persistence,client}/
```

ArchUnit pattern `..*.application.command..` enables matrix rule encoding to work regardless of package prefix.

### Event consumption is separate

Outbox-driven event consumption is **not** on the matrix. It's loose coupling (async, eventual, decoupled-in-time). Each module's spec lists events consumed/emitted separately.

## Consequences

### Positive

- **Single source of truth** for module boundaries. New developers read one document.
- **CI-enforced**: violations caught at PR time, not in code review.
- **Architecture decisions documented as code**: ArchUnit rule comments reference matrix rows.
- **Refactoring confidence**: when a rule fails, the matrix + rule comment explain *why*.
- **Onboarding aid**: "read ModuleDependencyMatrixTest.java; you'll know our architecture."
- **Prevents erosion**: 23 rules are enough to enforce all critical invariants; humans cannot remember 23 invariants over 12 months without help.

### Negative

- **Initial rule-writing cost** (~1-2 days during Phase 4).
- **Cost of changing the matrix**: requires PR review + ArchUnit rule update + this ADR's review. Intentional friction.
- **False positives**: occasionally a legitimate refactor will require matrix update. ArchUnit rule then needs adjustment.

### Neutral

- ArchUnit adds ~5s to test suite. Acceptable.
- Matrix and rules must stay in sync. Drift would be visible (one or the other failing).

## Rules for changing the matrix

Changing a `✗` to `Q`, `W`, or `Q+W` requires:

1. PR with motivation in description
2. ADR amending this one OR new ADR explaining why the new dependency is justified
3. ArchUnit rule update
4. Updated `04-module-contracts.md` matrix
5. Senior reviewer approval

Changing a `W` to `✗` (tightening) requires:

1. PR with refactor showing the dependency removed
2. ArchUnit rule update
3. Matrix update

Adding a new module requires:

1. ADR for the new module
2. Matrix row + column additions (all `✗` by default)
3. Module spec following the per-module template

## Anti-patterns this ADR rules out

- Justifying a cross-module dep in PR description without matrix update
- "We can fix this later" comments next to ArchUnit `@ArchIgnore`
- Bypassing matrix by routing through `shared` kernel
- Repository injection in reporting (or any consumer module)
- Catalog importing pricing classes for "convenience"
- Nested command-to-command chains across modules

## Related

- ADR-001 Multi-tenancy
- ADR-002 Append-only ledger
- ADR-005 Outbox pattern
- ADR-007 RLS context propagation
- ADR-019 Display name composition (Java-side pattern referenced by audit composer)
- ADR-020 Correlation ID Pattern
- Phase 4 Module Contracts (`docs/architecture/04-module-contracts.md`)
- Phase 6.A Java stack
- Phase 6.B JPA + JOOQ hybrid
