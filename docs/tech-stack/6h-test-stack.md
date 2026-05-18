# Phase 6.H — Test Stack

> **Status:** Locked
> **Phase:** 6.H

## Decisions

| Concern | Decision |
|---|---|
| Test pyramid | Static + Unit + Integration + ArchUnit + 3-5 E2E smoke (MVP) |
| Test framework | JUnit 5 |
| Integration framework | Testcontainers + Spring Boot test |
| Container reuse | `withReuse(true)` local, disabled in CI |
| Schema init | Flyway migrate once + TRUNCATE per test |
| Container singleton | PostgreSQL + Gotenberg shared across test classes |
| ArchUnit | 20+ rules, mandatory CI gate |
| Spring Modulith verification | `modules.verify()` mandatory CI gate |
| RLS isolation test | Parametrized test on all ~45 tenant tables |
| Append-only test | UPDATE/DELETE expected to throw |
| Cost snapshot immutability | Post-COMPLETED modification expected to throw |
| Sequence concurrency | 1000 concurrent allocations, gap-free assertion |
| Service test approach | Real DB integration dominant; mock only for pure logic |
| Web slice tests | `@WebMvcTest` + MockMvc + `@WithMockStockAppUser` |
| Full API tests | REST Assured + random port + auth flow |
| OpenAPI contract validation | swagger-request-validator + frontend types diff check |
| Concurrent race test | CyclicBarrier pattern |
| Idempotency test | Same key twice, single side-effect assertion |
| Frontend unit | Vitest |
| Frontend component | React Testing Library + user-event |
| Frontend API mock | MSW |
| Frontend E2E | 3-5 Playwright smoke tests (MVP) |
| Critical path coverage | 100% happy + error scenarios for 7 flows |
| CI matrix | arch+unit (5min) + integration (20min) + frontend (10min) + E2E (5min) |
| Backend coverage | 60% overall, 80% critical packages, JaCoCo enforced |
| Frontend coverage | 60% overall, 80% pos+auth, Vitest enforced |
| Test data | Java builders dominant; SQL fixtures for complex state |
| Performance | MVP manual benchmarks; k6 v1.1+ |

## Test pyramid (MVP)

```
                         ┌──────────────────┐
                         │  E2E (Playwright)│  3-5 smoke tests
                         ├──────────────────┤
                         │  Integration     │  ~200 tests, 35% coverage
                         │  Testcontainers  │
                       ╱ ├──────────────────┤ ╲
                      ╱  │   ArchUnit       │  ╲  20+ rules
                     ╱   │   Modulith       │   ╲
                    ╱    ├──────────────────┤    ╲
                   ╱     │     Unit         │     ╲  ~800 tests, 60% coverage
                  ╱      │  JUnit + Vitest  │      ╲
                 ╱       ├──────────────────┤       ╲
                ╱        │ Static (TS + ESLint)     ╲
               ╱_________└──────────────────┘________╲
```

## E2E smoke tests (MVP minimum 3)

| # | Flow | Why |
|---|---|---|
| 1 | Login → POS screen | Auth + routing + initial render |
| 2 | Barcode scan / manual add → cart total correct | POS happy path, Dinero correctness |
| 3 | Complete sale → success screen / receipt ready | End-to-end DB + Gotenberg + state machine |
| 4 (optional) | Stock insufficient error display | Negative path |
| 5 (optional) | Forbidden screen for unauthorized user | Auth boundary |

Playwright skeleton in Sprint 0, tests grow as features arrive.

## Integration test base

```java
public abstract class IntegrationTestBase {

    static final PostgreSQLContainer<?> POSTGRES;
    static final GenericContainer<?> GOTENBERG;

    static {
        POSTGRES = new PostgreSQLContainer<>("postgres:16-alpine")
            .withDatabaseName("stockapp_test")
            .withUsername("test").withPassword("test")
            .withReuse(true);
        POSTGRES.start();

        GOTENBERG = new GenericContainer<>("gotenberg/gotenberg:8")
            .withExposedPorts(3000).withReuse(true);
        GOTENBERG.start();
    }

    @DynamicPropertySource
    static void register(DynamicPropertyRegistry r) {
        r.add("spring.datasource.url", POSTGRES::getJdbcUrl);
        r.add("spring.datasource.username", POSTGRES::getUsername);
        r.add("spring.datasource.password", POSTGRES::getPassword);
        r.add("stockapp.gotenberg.url", () -> 
            "http://" + GOTENBERG.getHost() + ":" + GOTENBERG.getMappedPort(3000));
    }

    @BeforeEach
    void setupTenantContext() {
        truncateAllTenantTables();
        seedBaseTenant();
        SecurityContextHolder.setContext(testSecurityContext(TEST_TENANT_ID, TEST_USER_ID));
    }
}
```

## Key test patterns

### RLS isolation (parametrized, all tables)

```java
@ParameterizedTest
@MethodSource("allTenantScopedTables")
void every_tenant_scoped_table_enforces_rls(String tableName) {
    SecurityContextHolder.clearContext();
    var count = transactionTemplate.execute(status ->
        jdbc.queryForObject("SELECT count(*) FROM " + tableName, Integer.class)
    );
    assertThat(count).isZero();
}

static Stream<String> allTenantScopedTables() {
    return Stream.of(
        "sales", "sale_items", "sale_payments", "payment_attempts",
        "returns", "return_items", "exchange_groups",
        "purchase_invoices", "purchase_invoice_items",
        "stock_movements", "stock_balances", "transfers", "transfer_items",
        "count_sessions", "count_items", "stock_adjustments",
        "account_movements", "account_balances", "account_profiles",
        "payments", "payment_allocations", "account_aging",
        "cash_movements", "register_sessions", "cash_registers", "z_reports",
        "parties", "party_contacts", "party_documents",
        "products", "product_variants", "product_variant_barcodes",
        "categories", "brands", "seasons", "price_lists", "variant_prices",
        "users", "user_role_assignments", "stores",
        "outbox_events", "audit_event_log", "process_instances",
        "user_sessions", "password_reset_tokens"
    );
}
```

### Concurrent race (last unit scenario)

```java
@Test
void concurrent_sales_of_last_unit_one_succeeds_one_fails() throws InterruptedException {
    var variantId = seedVariant();
    seedStock(variantId, TEST_STORE_ID, 1);

    var executor = Executors.newFixedThreadPool(2);
    var barrier = new CyclicBarrier(2);
    var results = new ConcurrentHashMap<Integer, Outcome>();

    for (int i = 0; i < 2; i++) {
        final int idx = i;
        executor.submit(() -> {
            try {
                barrier.await();
                var saleId = saleCommand.createDraft(/*...*/);
                saleCommand.addItem(saleId, addItemCommand(variantId, 1));
                saleCommand.complete(saleId, completeCommand());
                results.put(idx, Outcome.SUCCESS);
            } catch (InsufficientStockException e) {
                results.put(idx, Outcome.INSUFFICIENT_STOCK);
            }
        });
    }
    executor.shutdown();
    executor.awaitTermination(10, SECONDS);

    long successes = results.values().stream().filter(o -> o == Outcome.SUCCESS).count();
    long insufficient = results.values().stream().filter(o -> o == Outcome.INSUFFICIENT_STOCK).count();
    
    assertThat(successes).isEqualTo(1);
    assertThat(insufficient).isEqualTo(1);
    assertThat(stockQuery.findBalance(variantId, TEST_STORE_ID).quantity())
        .isEqualByComparingTo("0");
}
```

### Sequence allocator gap-free

```java
@Test
void document_sequence_is_gap_free_under_concurrency() throws InterruptedException {
    var threads = 20, iterations = 50;
    var executor = Executors.newFixedThreadPool(threads);
    var latch = new CountDownLatch(threads * iterations);
    var allocated = ConcurrentHashMap.<Long>newKeySet();

    for (int i = 0; i < threads * iterations; i++) {
        executor.submit(() -> {
            try {
                var n = transactionTemplate.execute(s ->
                    sequenceAllocator.allocate(TEST_TENANT_ID, TEST_STORE_ID, "SALE_NUMBER", 2026)
                );
                allocated.add(n);
            } finally { latch.countDown(); }
        });
    }
    latch.await(30, SECONDS);

    assertThat(allocated).hasSize(threads * iterations);
    var min = Collections.min(allocated);
    var max = Collections.max(allocated);
    assertThat(max - min + 1).isEqualTo(allocated.size());
}
```

## ArchUnit rules (selected)

Critical orchestrator constraint (revised per Phase 6.H discussion):

```java
@ArchTest
static final ArchRule completion_orchestrator_public_api_thin =
    classes().that().haveSimpleNameEndingWith("CompletionOrchestrator")
        .should(havePublicMethodsAtMost(5))
        .because("Orchestrators expose few public entry points");

@ArchTest
static final ArchRule completion_orchestrator_file_size =
    classes().that().haveSimpleNameEndingWith("CompletionOrchestrator")
        .should(haveSourceFileLinesAtMost(800))
        .because("Orchestrators that exceed 800 LOC accumulate too much logic");
```

Full rule set in `ArchitectureTests` (see also `docs/tech-stack/6c-modular-monolith.md`).

## CI pipeline

```yaml
# .github/workflows/ci.yml
jobs:
  arch-and-unit:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-java@v4
        with: { distribution: 'temurin', java-version: '21' }
      - run: mvn -B test -P arch,unit
      
  integration:
    runs-on: ubuntu-latest
    timeout-minutes: 20
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-java@v4
        with: { distribution: 'temurin', java-version: '21' }
      - run: mvn -B verify -P integration
  
  frontend:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/setup-node@v4
        with: { node-version: '22', cache: 'npm' }
      - run: cd frontend && npm ci && npm run typecheck && npm run lint && npm run test && npm run build
  
  e2e-smoke:
    runs-on: ubuntu-latest
    needs: [integration, frontend]
    steps:
      - uses: actions/checkout@v4
      - run: docker compose -f docker-compose-test.yml up -d
      - run: cd frontend && npm ci && npx playwright install --with-deps && npm run e2e
  
  required:
    needs: [arch-and-unit, integration, frontend, e2e-smoke]
    runs-on: ubuntu-latest
    steps:
      - run: echo "All checks passed"
```

Branch protection: main requires `required` job pass.

## Coverage gates

### Backend (JaCoCo)

```xml
<rule>
  <element>BUNDLE</element>
  <limits>
    <limit><counter>LINE</counter><minimum>0.60</minimum></limit>
  </limits>
</rule>
<rule>
  <element>PACKAGE</element>
  <includes>
    <include>com.stockapp.modules.sales.internal.*</include>
    <include>com.stockapp.modules.inventory.internal.*</include>
    <include>com.stockapp.modules.financial.internal.*</include>
  </includes>
  <limits>
    <limit><counter>LINE</counter><minimum>0.80</minimum></limit>
  </limits>
</rule>
```

### Frontend (Vitest)

```typescript
coverage: {
  provider: 'v8',
  thresholds: { lines: 60, functions: 60, branches: 60, statements: 60 },
  exclude: ['**/*.test.ts', '**/*.test.tsx', '**/mocks/**'],
}
```

## Cross-references

- ArchUnit rules: spread across phase docs, consolidated in `ArchitectureTests`
- Module rules: `docs/tech-stack/6c-modular-monolith.md`
- Worker rules: `docs/architecture/worker-patterns.md`
