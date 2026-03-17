---
name: observability
description: >
  Optional observability stack using OpenObserve. Use this skill when the user asks to
  "add observability", "set up monitoring", "set up logging", "centralize logs",
  "add metrics", "add tracing", "monitor the app", or when discussing log aggregation,
  metrics collection, distributed tracing, or application performance monitoring.
  This skill covers the OpenObserve Kamal accessory recipe, ingestion endpoint reference,
  application instrumentation guidance, and data retention.
---

# Observability with OpenObserve

## Overview

OpenObserve is a lightweight, single-binary observability platform that handles logs, metrics, and traces. It runs as a Kamal accessory on its own VM, with a web dashboard for querying and visualization.

This is an **optional** component. It is not required for the application to run. Add it when the user asks for centralized logging, monitoring, or observability.

**What this skill covers:**

1. OpenObserve Kamal accessory recipe (infrastructure)
2. Ingestion API endpoints and authentication (reference for app integration)
3. Application instrumentation guidance (what env vars to set, which SDK to use)
4. Data retention and dashboard persistence

**What this skill does NOT cover:** application-level code for sending logs/metrics/traces. The **tech-stack** skill owns application code changes. This skill provides the infrastructure and API reference that the tech-stack skill uses.

## OpenObserve Accessory Recipe

### Complete Accessory Definition

The full accessory definition goes in the environment-specific config (`config/deploy.<env>.yml`):

```yaml
# config/deploy.preview.yml
accessories:
  observability:
    image: public.ecr.aws/zinclabs/openobserve:v0.70.0
    host: <%= ENV['INFRA_OBSERVABILITY_IP'] %>
    port: "5080:5080"
    proxy:
      host: o2.<%= ENV['INFRA_OBSERVABILITY_IP'] %>.nip.io
      ssl: true
      app_port: 5080
      healthcheck:
        path: /healthz
    env:
      clear:
        ZO_ROOT_USER_EMAIL: "admin@openobserve.local"
        ZO_LOCAL_MODE: "true"
        ZO_DATA_DIR: "/data/openobserve/"
        ZO_COMPACT_DATA_RETENTION_DAYS: "30"
        ZO_COMPACT_ENABLED: "true"
        ZO_TELEMETRY: "false"
        ZO_UI_ENABLED: "true"
        RUST_LOG: "warn"
      secret:
        - ZO_ROOT_USER_PASSWORD
        - ZO_ROOT_USER_TOKEN
    directories:
      - /data/openobserve:/data/openobserve
```

Key points:

- **Image**: `public.ecr.aws/zinclabs/openobserve` — single-binary, single-container. Check [OpenObserve releases](https://github.com/openobserve/openobserve/releases) for the latest stable version and update the tag
- **Port `5080:5080`**: Published on the host for internal access from other VMs. The app and workers connect here via CloudStack internal DNS (`observability:5080`). The proxy handles external HTTPS access for the dashboard
- **Proxy**: Web-facing for the dashboard. Uses `/healthz` as the health check (OpenObserve's actual health endpoint — not `/up`)
- **`ZO_LOCAL_MODE: "true"`**: Standalone single-node mode. No external dependencies (no S3, no separate metadata store)
- **`ZO_DATA_DIR: "/data/openobserve/"`**: All data (streams, WAL, metadata, cache) stored under this directory. Must match the `directories` mount
- **`ZO_COMPACT_DATA_RETENTION_DAYS: "30"`**: Data older than 30 days is automatically deleted during compaction. Adjust based on needs
- **`RUST_LOG: "warn"`**: OpenObserve's own log level. Use `debug` for troubleshooting, `trace` for detailed diagnostics
- **Directories mount**: `/data/openobserve` on the host disk → same path in the container. Subdirectory of `/data/` (the attached persistent disk with snapshot-based DR)

### Dashboard and Configuration Persistence

OpenObserve stores **everything** in `ZO_DATA_DIR`:

| Subdirectory | Contents |
|---|---|
| `stream/` | Log, metric, and trace stream data (Parquet files, zstd-compressed) |
| `wal/` | Write-ahead logs (in-flight data before compaction) |
| `db/` | Metadata database — **dashboards, alerts, users, saved queries, stream schemas** |
| `cache/` | Disk cache for query acceleration |
| `tmp/` | Temporary files |

Since all data lives under `/data/openobserve` on the attached disk, it is:
- **Backed up** via scheduled snapshots (same as database data)
- **Recoverable** via the standard DR procedure (`recover: true` in the deploy workflow)
- **Persistent** across accessory reboots and redeploys

User-created dashboards, alert rules, and saved queries are in `db/` and are fully recoverable.

### Environment Variable Reference

These are the most relevant configuration variables. All have sensible defaults for a single-node deployment:

| Variable | Default | Description |
|---|---|---|
| `ZO_ROOT_USER_EMAIL` | (required) | Admin email for login and API auth. Set in `env.clear` |
| `ZO_ROOT_USER_PASSWORD` | (required) | Admin password. Set in `env.secret` |
| `ZO_LOCAL_MODE` | `true` | Standalone mode (no S3/cluster) |
| `ZO_DATA_DIR` | `./data/openobserve/` | Data directory — set to `/data/openobserve/` |
| `ZO_HTTP_PORT` | `5080` | HTTP port for API and UI |
| `ZO_COMPACT_DATA_RETENTION_DAYS` | `3650` | Days to retain data — set to `30` |
| `ZO_COMPACT_ENABLED` | `true` | Enable background compaction |
| `ZO_COMPACT_INTERVAL` | `10` | Compaction check interval (seconds) |
| `ZO_TELEMETRY` | `true` | Usage telemetry to OpenObserve team — set to `false` |
| `ZO_UI_ENABLED` | `true` | Enable web dashboard |
| `ZO_BLOOM_FILTER_ENABLED` | `true` | Bloom filters for faster log search |
| `ZO_ENABLE_INVERTED_INDEX` | `true` | Inverted index for full-text search |
| `ZO_DISK_CACHE_ENABLED` | `true` | Disk cache for query performance |
| `ZO_PARQUET_COMPRESSION` | `zstd` | Compression algorithm for stored data |
| `RUST_LOG` | `info` | OpenObserve's own log level |

For the full list, see the [OpenObserve environment variable documentation](https://openobserve.ai/docs/environment-variables/).

## Credentials

OpenObserve requires `ZO_ROOT_USER_EMAIL` and `ZO_ROOT_USER_PASSWORD` to start (there is no way to disable auth). The email goes in `env.clear`; the password goes through the secrets pipeline. OpenObserve also supports `ZO_ROOT_USER_TOKEN` for Bearer-based API auth — this is what applications use to send data, keeping them decoupled from the admin email/password.

### GitHub Secret

Create one GitHub Secret per environment:

| GitHub Secret | Description |
|---|---|
| `ZO_ROOT_USER_PASSWORD` | OpenObserve admin password (preview) |
| `ZO_ROOT_USER_PASSWORD_PRODUCTION` | OpenObserve admin password (production) |

The agent generates a random password and sets it directly with `gh secret set --body` (same pattern as `POSTGRES_PASSWORD`).

### Kamal Secrets Files

`ZO_ROOT_USER_TOKEN` is derived from `ZO_ROOT_USER_PASSWORD` — it is not a separate GitHub Secret:

```bash
# .kamal/secrets.preview — add to existing file
ZO_ROOT_USER_PASSWORD=$ZO_ROOT_USER_PASSWORD
ZO_ROOT_USER_TOKEN=$ZO_ROOT_USER_PASSWORD
```

```bash
# .kamal/secrets.production — add to existing file
ZO_ROOT_USER_PASSWORD=$ZO_ROOT_USER_PASSWORD_PRODUCTION
ZO_ROOT_USER_TOKEN=$ZO_ROOT_USER_PASSWORD_PRODUCTION
```

### Kamal Config

The accessory receives `ZO_ROOT_USER_PASSWORD` and `ZO_ROOT_USER_TOKEN` via its own `env.secret` (already in the recipe above). The app only needs the token — add it to the app's `env.secret`:

```yaml
# config/deploy.<env>.yml — in each environment's env.secret list
env:
  secret:
    # ... existing secrets
    - ZO_ROOT_USER_TOKEN
```

### Workflow env: Block

Add the secret to the deploy job's `env:` block:

```yaml
# .github/workflows/deploy-preview.yml
deploy:
  needs: infra
  runs-on: ubuntu-latest
  env:
    # ... existing secrets
    ZO_ROOT_USER_PASSWORD: ${{ secrets.ZO_ROOT_USER_PASSWORD }}
```

## Ingestion Endpoints

OpenObserve exposes HTTP endpoints for receiving logs, metrics, and traces. All endpoints require authentication. Applications use Bearer auth (`Authorization: Bearer <token>`) with the `ZO_ROOT_USER_TOKEN` env var.

The base URL from within the CloudStack network is `http://observability:5080` (via CloudStack internal DNS). The organization ID is `default` (OpenObserve's default organization).

### OTLP HTTP Endpoints

| Signal | Endpoint | Format |
|---|---|---|
| Logs | `POST /api/{org}/v1/logs` | OTLP HTTP (protobuf) |
| Metrics | `POST /api/{org}/v1/metrics` | OTLP HTTP (protobuf) |
| Traces | `POST /api/{org}/v1/traces` | OTLP HTTP (protobuf) |

### Health Check

| Endpoint | Description |
|---|---|
| `GET /healthz` | Returns 200 when healthy |
| `GET /metrics` | Prometheus metrics (OpenObserve's own metrics) |

## Application Configuration

To send telemetry from the application to OpenObserve, set these environment variables in the Kamal config.

### Environment Variables for the App

Add to `env.clear` in `config/deploy.yml` (common to all environments):

```yaml
# config/deploy.yml
env:
  clear:
    # ... existing vars
    OTEL_EXPORTER_OTLP_ENDPOINT: "http://observability:5080/api/default"
    OTEL_SERVICE_NAME: <%= ENV['REPO_NAME'] %>
```

`ZO_ROOT_USER_TOKEN` comes from `env.secret` (see [Credentials](#credentials)). The application uses it as a Bearer token for all HTTP requests to OpenObserve.

### OpenTelemetry SDK

The OpenTelemetry SDK provides a unified way to send logs, metrics, and traces. For Go applications:

1. **Dependencies**: `go.opentelemetry.io/otel`, `go.opentelemetry.io/otel/exporters/otlp/otlplog/otlploghttp`, `go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetrichttp`, `go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp`
2. **Log bridge**: `go.opentelemetry.io/contrib/bridges/otelslog` bridges `slog` to OTLP
3. **Auth**: Set `Authorization: Bearer <token>` header on the OTLP HTTP exporter using `ZO_ROOT_USER_TOKEN`
4. **Endpoint**: Reads from `OTEL_EXPORTER_OTLP_ENDPOINT` automatically

The tech-stack skill handles the actual Go code integration. This skill provides the infrastructure reference.

## Data Retention

### OpenObserve Retention

| Variable | Value | Effect |
|---|---|---|
| `ZO_COMPACT_DATA_RETENTION_DAYS` | `30` | Data older than 30 days is deleted during compaction |
| `ZO_COMPACT_ENABLED` | `true` | Compaction runs automatically |
| `ZO_COMPACT_INTERVAL` | `10` (default) | Compaction checks every 10 seconds |
| `ZO_PARQUET_COMPRESSION` | `zstd` (default) | Efficient compression reduces disk usage |

To change retention, update `ZO_COMPACT_DATA_RETENTION_DAYS` in the accessory's `env.clear` and reboot the accessory (`kamal accessory reboot observability`).

Retention can also be configured **per stream** in the OpenObserve dashboard (Settings > Streams > Edit), overriding the global default.

### Disk Sizing

The observability VM's disk stores compressed log/metric/trace data. Sizing depends on ingestion volume:

| Log volume | 30-day estimate (zstd compressed) | Recommended `disk_size_gb` |
|---|---|---|
| Low (< 100 MB/day raw) | ~1-3 GB | 20 |
| Medium (100 MB - 1 GB/day raw) | ~3-15 GB | 50 |
| High (1-10 GB/day raw) | ~15-100 GB | 200 |

zstd compression typically achieves 5-10x compression on structured JSON logs. Start with 50 GB and monitor usage in the OpenObserve dashboard (Ingestion > Overview).

## Sync with Workflow

### Provisioning JSON

Add the observability accessory to the `accessories` JSON in the deploy workflow:

```json
[
  {"name": "db", "plan": "medium", "disk_size_gb": 20},
  {"name": "observability", "plan": "small", "disk_size_gb": 50, "ports": "80,443"}
]
```

- **`name: "observability"`**: Matches the accessory name in the Kamal config and sets the CloudStack DNS hostname
- **`plan: "small"`**: 2 vCPU, 2 GiB RAM — sufficient for moderate log volumes. Scale to `medium` (4 GiB) for higher throughput
- **`disk_size_gb: 50`**: Persistent disk for log storage (see [Disk Sizing](#disk-sizing) above)
- **`ports: "80,443"`**: Open for kamal-proxy (dashboard HTTPS access). Port 5080 is NOT opened publicly — internal traffic uses CloudStack DNS over the private network

### Infrastructure Document

Update `docs/INFRASTRUCTURE.md` to include the observability accessory (forward/reverse sync with the Kamal config and workflow, as required by the app-deploy skill).

### Dashboard URL

After deployment, the OpenObserve dashboard is accessible at:

- **Without custom domain**: `https://o2.<INFRA_OBSERVABILITY_IP>.nip.io`
- **With custom domain**: Configure a DNS A record and update `proxy.host` in the accessory definition

Log in with the email from `env.clear` (`admin@openobserve.local`) and the password from the `ZO_ROOT_USER_PASSWORD` GitHub Secret.
