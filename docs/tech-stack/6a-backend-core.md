# Phase 6.A — Backend Core

> **Status:** Locked
> **Phase:** 6.A

## Decisions

| Concern | Decision | Notes |
|---|---|---|
| Language | **Java 21 LTS** | Temurin distribution |
| Framework | **Spring Boot 4.0.x** | Spring Framework 7.x |
| Build tool | **Maven** | Multi-module v1.1+ |
| ORM (commands) | **Spring Data JPA** | Aggregate state mutations |
| Query DSL (queries) | **JOOQ** | Reporting, batch, complex CTE |
| Migration | **Flyway** | Application startup migrate |
| Database | **PostgreSQL 16+** | RLS, JSONB, GIST, partial indexes |
| Module discipline | **Spring Modulith** | Structure verification + docs |
| Architecture tests | **ArchUnit** | 20+ rules |
| Test framework | **JUnit 5** | + Testcontainers |
| API style | **REST** (Spring MVC) | OpenAPI 3.1 via springdoc-openapi |

## Why Java 21 (not 25)

The argument for Java 25 (NFTC runway, virtual thread maturity) was offset by ecosystem inertia: production footprint of Java 21 in mid-2026 is enormous. Domain complexity is what threatens this project, not framework newness.

Java 21 + Temurin = free updates through 2031 via OpenJDK distributions. Oracle JDK NFTC concerns do not apply.

Java 25 migration is a one-line `pom.xml` change when virtual thread performance benefit becomes measurable. Roadmap entry.

## Why Spring Boot 4.0.x

Spring Boot 3.5 OSS support ends June 30, 2026 — six weeks after this decision. Spring Boot 4.0.x is the current actively-supported branch (support through end of 2026 minimum, Spring Framework 7 baseline).

## Why JPA + JOOQ hybrid

Clear command/query separation:

- **JPA** — aggregate state mutations, repository pattern, entity lifecycle, validation, cascade
- **JOOQ** — complex reports, batch INSERT, CTEs, materialized view refresh, JSON path queries, window functions, UPSERT

Forbidden: mixing both in the same repository. If a `SaleRepository` needs a complex query, create a separate `SaleQueryService` using JOOQ.

ArchUnit rule:
```java
classes().that().implement(JpaRepository.class)
    .should().notDependOnClassesThat().resideInAPackage("org.jooq..");
```

## Why Spring Modulith

Selective use:

- ✅ Module structure verification (`ApplicationModules.verify()` in CI)
- ✅ Documentation generation (PlantUML, Mermaid)
- ✅ Inter-module `@ApplicationModuleListener` for internal eventual consistency
- ❌ Outbox externalization (we use our own outbox schema per Phase 2D)

## Maven structure

MVP single module + package-by-feature:

```
stock-app/
├── pom.xml
└── src/main/java/com/stockapp/
    ├── StockAppApplication.java
    ├── modules/
    │   ├── identity/{api,internal}
    │   ├── catalog/{api,internal}
    │   ├── inventory/{api,internal}
    │   ├── sales/{api,internal}
    │   ├── purchasing/{api,internal}
    │   ├── party/{api,internal}
    │   ├── financial/{api,internal}
    │   ├── cashregister/{api,internal}
    │   ├── fx/{api,internal}
    │   └── reporting/{api,internal}
    └── shared/
        ├── audit/
        ├── outbox/
        ├── security/
        └── common/
```

Migration to multi-module when boundaries are sufficiently exercised (v1.1+).

## Why not Kotlin

Java skill of the team is the deciding factor. Kotlin would add learning surface area; domain complexity already saturates that capacity. Pure pragmatic choice.

## Why not GraalVM native image

MVP: standard JVM JIT. Native image deferred until startup time becomes operationally painful (Hetzner VPS deploy is rare, restart latency irrelevant). Roadmap entry only.

## Spring Boot dependencies (selected)

```xml
<!-- Core -->
spring-boot-starter-web
spring-boot-starter-security
spring-boot-starter-data-jpa
spring-boot-starter-validation
spring-boot-starter-actuator
spring-boot-starter-thymeleaf      <!-- document templates -->

<!-- DB -->
org.postgresql:postgresql
org.flywaydb:flyway-core
org.jooq:jooq
org.jooq:jooq-codegen-maven        <!-- build-time -->

<!-- JSON -->
com.fasterxml.jackson.module:jackson-module-parameter-names
com.fasterxml.jackson.datatype:jackson-datatype-jsr310

<!-- Modularity & arch -->
org.springframework.modulith:spring-modulith-starter-core
org.springframework.modulith:spring-modulith-starter-jpa
com.tngtech.archunit:archunit-junit5

<!-- Scheduling -->
net.javacrumbs.shedlock:shedlock-spring
net.javacrumbs.shedlock:shedlock-provider-jdbc-template

<!-- Auth -->
org.springframework.security:spring-security-oauth2-jose  <!-- JWT -->
org.passay:passay                                          <!-- password policy -->
com.github.ben-manes.caffeine:caffeine                     <!-- permission cache -->

<!-- Rate limiting -->
com.bucket4j:bucket4j-core

<!-- Logging -->
net.logstash.logback:logstash-logback-encoder

<!-- Observability -->
io.micrometer:micrometer-registry-prometheus
io.opentelemetry.instrumentation:opentelemetry-spring-boot-starter
io.sentry:sentry-spring-boot-starter-jakarta

<!-- Test -->
spring-boot-starter-test
org.testcontainers:postgresql
org.testcontainers:junit-jupiter
io.rest-assured:rest-assured
com.atlassian.oai:swagger-request-validator
```

Final versions resolved at Phase 7 kickoff.
