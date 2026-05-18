# Phase 6.I — DevOps & Deploy

> **Status:** Locked
> **Phase:** 6.I

## MVP philosophy

**Zero monthly cost. Ship product first. Upgrade infrastructure when paying customers arrive.**

Premature infra investment delays the only thing that matters: getting the product into pilot users' hands.

## Decisions (MVP)

| Concern | Decision | Cost |
|---|---|---|
| **Frontend deploy** | Cloudflare Pages | €0 |
| **Backend deploy** | Fly.io Free (cold start avoidance vs Render) | €0 |
| **Database** | Neon Free PostgreSQL | €0 |
| **PDF generation** | Gotenberg as second Fly.io app | €0 |
| **Document storage** | Cloudflare R2 Free (10 GB) | €0 |
| **Backup** | GitHub Actions weekly `pg_dump` → R2 (GPG encrypted) | €0 |
| **CI/CD** | GitHub Actions | €0 |
| **Container registry** | GHCR | €0 |
| **Error tracking** | Sentry SaaS Free (5K events/month) | €0 |
| **Local dev** | docker-compose: postgres, gotenberg, mailhog | €0 |
| **Monitoring** | Fly.io logs + Sentry + GitHub Actions logs | €0 |
| **Domain** | None MVP (`*.pages.dev`, `*.fly.dev` subdomains) | €0 |
| **SSL** | Automatic (Cloudflare, Fly.io) | €0 |
| **TOTAL** | | **€0/month** |

## Why Fly.io over Render

Render Free tier sleeps after 15 min of inactivity. Cold start = 50-60 seconds. Unacceptable for POS pilot users.

Fly.io Free tier: 3 small VMs, no sleep, ~1s startup. Free reliability has limits (occasional outages historically), but cold start avoidance is the deciding factor.

## Why Neon over Supabase / Railway

- Native PostgreSQL (no abstraction layer)
- Schema features used (RLS, JSONB, materialized views) work without wrapper compatibility
- 0.5 GB free tier sufficient for first 3-4 pilot customers
- Branching feature useful for migration testing
- Auto-suspend after 5 min idle (cold start ~500ms, tolerable)

## Container builds

### Backend Dockerfile

```dockerfile
# Build stage
FROM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /build
COPY pom.xml .
RUN mvn dependency:go-offline -B
COPY src ./src
RUN mvn package -B -DskipTests
RUN java -Djarmode=layertools -jar target/*.jar extract --destination /build/layers

# Runtime stage
FROM eclipse-temurin:21-jre-alpine AS runtime
RUN apk add --no-cache curl tzdata && \
    cp /usr/share/zoneinfo/Europe/Istanbul /etc/localtime
RUN addgroup -S stockapp && adduser -S stockapp -G stockapp -h /app
WORKDIR /app
USER stockapp
COPY --from=build --chown=stockapp:stockapp /build/layers/dependencies/ ./
COPY --from=build --chown=stockapp:stockapp /build/layers/spring-boot-loader/ ./
COPY --from=build --chown=stockapp:stockapp /build/layers/snapshot-dependencies/ ./
COPY --from=build --chown=stockapp:stockapp /build/layers/application/ ./
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s --start-period=60s --retries=3 \
  CMD curl -fsS http://localhost:8080/actuator/health/liveness || exit 1

ENV JAVA_OPTS="-XX:MaxRAMPercentage=75.0 -XX:+UseG1GC -XX:+ExitOnOutOfMemoryError \
  -Djava.security.egd=file:/dev/./urandom -Duser.timezone=Europe/Istanbul"

ENTRYPOINT exec java $JAVA_OPTS org.springframework.boot.loader.launch.JarLauncher
```

### Frontend Dockerfile

(Cloudflare Pages builds directly from GitHub; Docker not strictly needed. The Dockerfile above is for self-hosted v1.1+ option.)

```dockerfile
FROM node:22-alpine AS build
WORKDIR /build
COPY frontend/package.json frontend/package-lock.json ./
RUN npm ci
COPY frontend/ ./
ARG VITE_API_BASE_URL VITE_SENTRY_DSN VITE_APP_VERSION
ENV VITE_API_BASE_URL=$VITE_API_BASE_URL VITE_SENTRY_DSN=$VITE_SENTRY_DSN VITE_APP_VERSION=$VITE_APP_VERSION
RUN npm run build

FROM nginx:alpine AS runtime
COPY --from=build /build/dist /usr/share/nginx/html
COPY infra/nginx/default.conf /etc/nginx/conf.d/default.conf
EXPOSE 80
```

## Fly.io configuration

### Backend `fly.toml`

```toml
app = "stockapp-backend"
primary_region = "fra"  # Frankfurt, ~30ms Turkey latency

[build]
  image = "ghcr.io/serdanberat/stockapp-backend:latest"

[env]
  SPRING_PROFILES_ACTIVE = "prod"
  GOTENBERG_URL = "http://stockapp-gotenberg.internal:3000"

[[services]]
  internal_port = 8080
  protocol = "tcp"
  auto_stop_machines = false
  auto_start_machines = true
  min_machines_running = 1

  [[services.http_checks]]
    interval = "15s"
    grace_period = "60s"
    method = "get"
    path = "/actuator/health/liveness"

  [[services.ports]]
    handlers = ["http"]
    port = 80

  [[services.ports]]
    handlers = ["tls", "http"]
    port = 443

[[vm]]
  cpu_kind = "shared"
  cpus = 1
  memory_mb = 1024
```

### Gotenberg `fly.toml`

```toml
app = "stockapp-gotenberg"
primary_region = "fra"

[build]
  image = "gotenberg/gotenberg:8"

[[services]]
  internal_port = 3000
  protocol = "tcp"
  auto_stop_machines = true   # save quota when idle
  auto_start_machines = true

[[vm]]
  cpu_kind = "shared"
  cpus = 1
  memory_mb = 1024
```

Internal networking: backend reaches gotenberg via `stockapp-gotenberg.internal:3000`.

## Local development

```yaml
# docker-compose.yml
services:
  postgres:
    image: postgres:16-alpine
    environment:
      POSTGRES_DB: stockapp
      POSTGRES_USER: stockapp
      POSTGRES_PASSWORD: stockapp_local_dev
    ports: ["127.0.0.1:5432:5432"]
    volumes: [postgres_data:/var/lib/postgresql/data]

  gotenberg:
    image: gotenberg/gotenberg:8
    ports: ["127.0.0.1:3000:3000"]
    deploy:
      resources:
        limits: { memory: 2G, cpus: '2.0' }

  mailhog:
    image: mailhog/mailhog
    ports: ["127.0.0.1:1025:1025", "127.0.0.1:8025:8025"]

  backend:
    build: { context: ., dockerfile: Dockerfile }
    environment:
      SPRING_PROFILES_ACTIVE: dev
      DB_URL: jdbc:postgresql://postgres:5432/stockapp
      DB_USER: stockapp
      DB_PASSWORD: stockapp_local_dev
      JWT_SECRET: dev_jwt_secret_min_32_chars_local
      TOKEN_PEPPER: dGVzdF9wZXBwZXJfYmFzZTY0X2VuY29kZWRfMzJfYnl0ZXM=
      GOTENBERG_URL: http://gotenberg:3000
      SMTP_HOST: mailhog
      SMTP_PORT: 1025
    ports: ["127.0.0.1:8080:8080"]
    depends_on:
      postgres: { condition: service_healthy }
      gotenberg: { condition: service_started }

  frontend:
    image: node:22-alpine
    working_dir: /app
    command: npm run dev -- --host 0.0.0.0
    environment:
      VITE_API_BASE_URL: http://localhost:8080/api/v1
    ports: ["127.0.0.1:5173:5173"]
    volumes:
      - ./frontend:/app
      - frontend_node_modules:/app/node_modules

volumes:
  postgres_data:
  frontend_node_modules:
```

## CI/CD pipelines

### `.github/workflows/ci.yml` (Phase 6.H)

Test pipeline (arch + unit + integration + frontend + E2E smoke).

### `.github/workflows/release.yml` (on tag push)

```yaml
on:
  push:
    tags: ['v*.*.*']

jobs:
  build-and-push:
    runs-on: ubuntu-latest
    permissions: { contents: read, packages: write }
    steps:
      - uses: actions/checkout@v4
      - uses: docker/setup-buildx-action@v3
      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      
      - uses: docker/build-push-action@v6
        with:
          context: .
          push: true
          tags: |
            ghcr.io/serdanberat/stockapp-backend:${{ github.ref_name }}
            ghcr.io/serdanberat/stockapp-backend:latest
          cache-from: type=gha
          cache-to: type=gha,mode=max
```

### `.github/workflows/deploy.yml` (manual)

```yaml
on:
  workflow_dispatch:
    inputs:
      version: { description: 'Version to deploy', required: true }

jobs:
  deploy-backend:
    runs-on: ubuntu-latest
    environment: production
    steps:
      - uses: superfly/flyctl-actions/setup-flyctl@master
      - run: flyctl deploy --app stockapp-backend --image ghcr.io/serdanberat/stockapp-backend:${{ inputs.version }}
        env: { FLY_API_TOKEN: ${{ secrets.FLY_API_TOKEN }} }
      
      - name: Notify Sentry of release
        uses: getsentry/action-release@v1
        with: { environment: production, version: ${{ inputs.version }} }
        env: { SENTRY_AUTH_TOKEN: ${{ secrets.SENTRY_AUTH_TOKEN }} }
```

### `.github/workflows/backup.yml` (scheduled)

```yaml
on:
  schedule:
    - cron: '0 3 * * 0'  # Sunday 03:00 UTC
  workflow_dispatch:

jobs:
  backup:
    runs-on: ubuntu-latest
    steps:
      - run: |
          pg_dump "$NEON_DATABASE_URL" -Fc -f backup-$(date +%Y%m%d).dump
          gpg --batch --yes --passphrase "$BACKUP_PASSPHRASE" \
              --symmetric --cipher-algo AES256 backup-*.dump
        env:
          NEON_DATABASE_URL: ${{ secrets.NEON_DATABASE_URL }}
          BACKUP_PASSPHRASE: ${{ secrets.BACKUP_PASSPHRASE }}
      
      - name: Upload to R2
        env:
          AWS_ACCESS_KEY_ID: ${{ secrets.R2_ACCESS_KEY }}
          AWS_SECRET_ACCESS_KEY: ${{ secrets.R2_SECRET_KEY }}
          AWS_ENDPOINT_URL_S3: https://${{ secrets.R2_ACCOUNT_ID }}.r2.cloudflarestorage.com
        run: |
          aws s3 cp backup-*.dump.gpg s3://stockapp-backups/postgres/
```

Backup encryption key stored only in GitHub Actions secrets + developer 1Password. Database compromise alone cannot read backups.

## Deploy strategy (MVP)

- **Manual trigger**: `workflow_dispatch` requires Berat approval
- **Tag-based**: only `v*.*.*` tags trigger release workflow
- **Off-hours**: deploy during low-traffic windows (Sunday night for Türkiye retail)
- **Health check rollback**: deploy script polls `/actuator/health/readiness`; if fail after 60s, restore previous machine

Single-instance downtime acceptable (5 min worst case). Multi-instance blue-green deferred to v1.1+.

## Migration strategy

**MVP**: Flyway migrates at app startup.

```yaml
spring.flyway:
  enabled: true
  baseline-on-migrate: true
  clean-disabled: true
```

**v1.1+**: Pre-deploy migration step (`flyway:migrate` as separate CI step before app deploy).

**Discipline**: backward-compatible migrations only. Column removals split across multiple releases:

```
v1: ADD COLUMN new_column; populate from old_column
v2: code switches to new_column
v3: DROP COLUMN old_column
```

Flyway does not support rollback. Forward-only migrations with compensating migrations on failure.

## Secret management

```
MVP: Fly.io secrets + GitHub Actions secrets
v1.1+: HashiCorp Vault or Doppler/Infisical
```

Set via:
```bash
fly secrets set JWT_SECRET=... TOKEN_PEPPER=... DB_URL=... -a stockapp-backend
```

## Backup & disaster recovery

| Layer | Mechanism | Retention |
|---|---|---|
| Application code | Git (distributed) | Forever |
| Database | Weekly `pg_dump` → R2, GPG encrypted | 30 days |
| Document storage | R2 (versioned bucket) | Forever |
| Neon snapshots | Neon platform built-in | 7 days (free tier) |

### Recovery scenarios

| Scenario | Action | RTO | RPO |
|---|---|---|---|
| App bug rollback | `flyctl deploy --image <prev-tag>` | 5 min | 0 |
| Data corruption | Restore from latest weekly backup | 30-60 min | 7 days worst case |
| Neon outage | Wait for Neon recovery; if extended, restore to standby PostgreSQL | 2-4 h | 7 days |
| Fly.io outage | Migrate to Hetzner CX22 (runbook) | 4-8 h | 0 (DB unaffected) |

## Triggered infrastructure upgrades

| Trigger | Action | New monthly cost |
|---|---|---|
| **First paying customer** | Hetzner CX22 backend + Neon Pro DB | ~€25 |
| **3 paying customers** | Hetzner CCX13 + add Sentry self-host plan | ~€40 |
| **10 paying customers** | Hetzner CCX23 + Sentry Pro + observability (Grafana/Loki) | ~€100 |
| **25+ paying customers** | Multi-instance + staging environment | ~€200 |
| **Multi-region need** | Cloudflare D1/Tigris hybrid arch | (v2 planning) |

Discipline: stay at current tier until trigger is met. Upgrading earlier delays revenue.

## Domain strategy

**MVP**: `stockapp-frontend.pages.dev` + `stockapp-backend.fly.dev`. No registration cost, ready immediately.

**Trigger (first paying customer)**: register `.com.tr` domain (~₺200/year), update DNS, Cloudflare + Fly.io SSL automatic.

## Observability (MVP minimal)

- **Logs**: Fly.io built-in log tail (`flyctl logs`)
- **Errors**: Sentry SaaS free tier
- **Uptime**: Fly.io machine health checks
- **Metrics endpoint**: `/actuator/prometheus` exists (basic auth), but no Prometheus scraping in MVP
- **CI logs**: GitHub Actions

No Grafana/Loki/Prometheus deployment in MVP. They activate with the 10-customer upgrade tier.

## Cross-references

- Phase 6.G observability decisions (alerts, dashboards, metrics catalog)
- Phase 6.H test stack (CI gates)
