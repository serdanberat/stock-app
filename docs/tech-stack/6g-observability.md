# Phase 6.G — Observability

> **Status:** Locked
> **Phase:** 6.G

## Decisions

| Concern | Decision |
|---|---|
| Log format | Structured JSON via logstash-logback-encoder |
| MDC context | trace_id, tenant_id, user_id, store_id, request path/method |
| Log levels | ERROR = alert trigger; conservative use |
| Sensitive masking | Logback custom converter + test enforcement |
| Metrics stack | Spring Actuator + Micrometer + Prometheus registry |
| Auto metrics | HTTP, JVM, Hikari, Tomcat (out-of-box) |
| Custom business metrics | Sales, inventory, financial, jobs, auth (~30 metrics) |
| Tenant tagging | No metric tag (MVP); DB queries for breakdown |
| Actuator security | Internal account, basic auth, isolated security chain |
| Distributed tracing | OpenTelemetry SDK + auto-instrumentation |
| OTLP exporter | noop (MVP); enabled when collector deployed |
| Trace ID in MDC | Active from day 1 |
| Manual spans | `@WithSpan` on critical methods |
| Health checks | Spring Actuator + custom (Gotenberg, Outbox lag) |
| Error tracking | Sentry SaaS free tier (MVP) |
| Error tracking v1.1+ | Self-hosted Sentry |
| Sentry config | send-default-pii: false, beforeSend filter with tenant tags |
| Frontend errors | Sentry React + ErrorBoundary + masked replay |
| Audit log vs app log | Strict separation (DB table vs stdout) |
| ArchUnit | `@AuditableAction` requires AuditLogService usage |
| MVP alerts (active) | 9 critical alerts |
| Observation-only (no alert) | Latency, tenant blocked, negative stock, FX errors, retry count |
| Pager | Single dev (SMS), PagerDuty v1.1+ |
| Dashboards | 5 Grafana dashboards, JSON in repo |
| Log retention | systemd journal + logrotate 30d MVP, centralized v1.1+ |
| Audit retention | DB long-term (regulatory), partitioning v1.1+ |
| PII discipline | Email/phone/name/address never in logs |

## MVP alert set (9 critical)

| # | Alert | Trigger | Destination |
|---|---|---|---|
| 1 | Service down | Health endpoint failing | SMS |
| 2 | HTTP 5xx rate | > 5% over 5 min | Slack + email |
| 3 | DB connection pool saturation | > 90% used | Slack |
| 4 | Disk space low | < 20% free | Email |
| 5 | Outbox pending high | > 1000 events for 10 min | Slack |
| 6 | DLQ event occurred | Any new DLQ row | Email + Slack |
| 7 | Gotenberg down | Health indicator DOWN | Slack |
| 8 | Failed login spike | > 100/5min/IP | Email + Slack |
| 9 | Z report generation failed | After day close + 1h no Z | SMS |

## Observation-only (dashboard, no alert)

- Latency P95 degradation (warn pattern only)
- Tenant status changes (TRIAL → SUSPENDED, etc.)
- Negative stock balance (any new row in adjustments)
- FX provider transient errors
- Document retry count rising

These are observed first to learn normal behavior; promoted to alerts based on baseline data.

## Logback configuration

```xml
<configuration>
    <appender name="STDOUT" class="ch.qos.logback.core.ConsoleAppender">
        <encoder class="net.logstash.logback.encoder.LogstashEncoder">
            <customFields>{"service":"stockapp","env":"${SPRING_PROFILES_ACTIVE}"}</customFields>
        </encoder>
    </appender>
    <root level="INFO"><appender-ref ref="STDOUT"/></root>
    <logger name="com.stockapp" level="DEBUG"/>
    <logger name="org.hibernate.SQL" level="WARN"/>
</configuration>
```

## MDC context filter

```java
@Component
@Order(Ordered.HIGHEST_PRECEDENCE + 10)
public class MdcContextFilter extends OncePerRequestFilter {
    @Override
    protected void doFilterInternal(HttpServletRequest req, HttpServletResponse res, FilterChain chain) {
        try {
            MDC.put("trace_id", extractOrGenerateTraceId(req));
            MDC.put("request_path", req.getRequestURI());
            
            var principal = currentPrincipal();
            if (principal != null) {
                MDC.put("tenant_id", principal.tenantId().toString());
                MDC.put("user_id", principal.userId().toString());
                MDC.put("tenant_code", principal.tenantCode());
            }
            
            res.setHeader("X-Trace-Id", MDC.get("trace_id"));
            chain.doFilter(req, res);
        } finally {
            MDC.clear();
        }
    }
}
```

## Custom business metrics

```java
@Component
public class SalesMetrics {
    private final Counter completedSales;
    private final Timer saleCompletionDuration;
    private final DistributionSummary saleTotalTry;

    public SalesMetrics(MeterRegistry registry) {
        completedSales = Counter.builder("stockapp.sales.completed").register(registry);
        saleCompletionDuration = Timer.builder("stockapp.sales.completion_duration")
            .publishPercentiles(0.5, 0.95, 0.99).register(registry);
        saleTotalTry = DistributionSummary.builder("stockapp.sales.total_try")
            .baseUnit("TRY").register(registry);
    }

    public void recordCompletion(Sale sale, Duration duration) {
        completedSales.increment();
        saleCompletionDuration.record(duration);
        saleTotalTry.record(sale.totalTry().doubleValue());
    }
}
```

## Metric categories (~30 total)

- **Sales**: completed, abandoned, admin_reversed, completion_duration, total_try distribution
- **Inventory**: stock_movements (direction, type), low_stock_variant_count, transfer_dispatches, transfer_receives, count_session_completions, count_session_variance
- **Financial**: payments_received (tender_type), payments_made, payments_reversed (reversal_type), total_receivables_try, total_payables_try, overdue_90plus_try
- **Jobs**: job_executions (job_name, outcome), job_duration, job_last_success_timestamp, outbox_dispatched, outbox_dead_lettered, outbox_pending_count, document_generated (type), document_failed
- **Auth**: login_attempts (outcome), password_resets, session_revocations (reason)
- **RLS health**: rls_leakage_detection_passes

## Sentry configuration

```yaml
sentry:
  dsn: ${SENTRY_DSN:}
  environment: ${SPRING_PROFILES_ACTIVE:dev}
  release: ${APP_VERSION}
  send-default-pii: false
  sample-rate: 1.0
  traces-sample-rate: 0.1
```

```java
@Configuration
public class SentryConfig {
    @Bean
    public Sentry.OptionsConfiguration<SentryOptions> sentryOptions() {
        return options -> options.setBeforeSend((event, hint) -> {
            if (event.getThrowable() instanceof ClientAbortException) return null;
            var principal = currentPrincipalSafe();
            if (principal != null) {
                event.setTag("tenant_code", principal.tenantCode());
            }
            return event;
        });
    }
}
```

## Health indicators

```java
@Component
public class GotenbergHealthIndicator implements HealthIndicator {
    public Health health() {
        try {
            var response = client.get().uri("/health").retrieve().toBodilessEntity();
            return response.getStatusCode().is2xxSuccessful() 
                ? Health.up().build() 
                : Health.down().withDetail("status", response.getStatusCode().value()).build();
        } catch (Exception e) {
            return Health.down(e).build();
        }
    }
}

@Component
public class OutboxLagHealthIndicator implements HealthIndicator {
    public Health health() {
        var oldestPending = outboxRepo.findOldestPending();
        if (oldestPending.isEmpty()) return Health.up().build();
        var lag = Duration.between(oldestPending.get().recordedAt(), Instant.now());
        return lag.toMinutes() > 5 
            ? Health.outOfService().withDetail("lag_seconds", lag.toSeconds()).build()
            : Health.up().withDetail("lag_seconds", lag.toSeconds()).build();
    }
}
```

## Audit log discipline

DB tables (`audit_event_log`, `security_audit_log`) ≠ application logs.

| | Application log | Audit log |
|---|---|---|
| Storage | stdout → centralized | PostgreSQL table |
| Format | JSON, semi-structured | Strong-schema, append-only |
| Retention | 30-90 days | Years (regulatory) |
| Mutability | Rotation/expiration | Immutable (REVOKE UPDATE/DELETE) |
| Tenant isolation | Tag/filter | RLS |
| Examples | "request received", "cache miss" | "user X approved BLIND return Y" |

ArchUnit:

```java
@ArchTest
static final ArchRule sensitive_actions_must_use_audit_log =
    classes().that().areAnnotatedWith(AuditableAction.class)
        .should().dependOnClassesThat().haveSimpleName("AuditLogService");
```

## Grafana dashboards (5)

1. **Service Health** — HTTP rate, latency, JVM, DB pool, Tomcat, disk, CPU
2. **Business Metrics** — sales/min, average sale TRY, top variants, refund rate
3. **Worker Health** — outbox dispatched, pending, DLQ trend, document generation, job durations, last success
4. **Auth & Security** — login attempts, active sessions, brute force, locked accounts
5. **FX Rates** — provider last-fetch, rate fluctuation, provider error rate

JSON exports in `infra/grafana/dashboards/`.

## PII discipline

- Email, phone, tax_id: **never** in logs (use IDs)
- Customer name: **never** in logs
- Address: **never** in logs
- Password, token: **never** (masked + tested)
- Financial figures: OK for operational debug; masked in Sentry

```java
@Test
void user_email_never_appears_in_application_logs() {
    var logCaptor = LogCaptor.forRoot();
    saleCommand.createDraft(...);
    customerService.createCustomer("Ahmet Yılmaz", "ahmet@example.com");
    
    var logs = logCaptor.getLogs();
    assertThat(logs).noneMatch(log -> log.contains("ahmet@example.com"));
    assertThat(logs).noneMatch(log -> log.contains("Ahmet Yılmaz"));
}
```

## MVP cost

- Sentry SaaS free: 5K events/month
- Prometheus + Grafana + Loki: self-hosted on same VPS (v1.1+)
- MVP: Fly.io logs + Sentry + GitHub Actions logs
