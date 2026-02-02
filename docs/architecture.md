# Architecture & Technical Design

This document covers the deployment topology, application architecture, and observability data flow for the Pyroscope continuous profiling demo.

## 1. System Overview

The project deploys a production-realistic JVM topology with continuous profiling, metrics collection, and dashboarding — ten containers on a single Docker Compose network (7 bank services + 3 observability infrastructure).

```mermaid
C4Context
    title System Context — Continuous Profiling Demo

    Person(user, "Developer / SRE", "Explores flame graphs & metrics")

    System_Boundary(compose, "Docker Compose Stack") {
        Container(s1, "vertx-server-1", "JVM / Vert.x", "main, order, payment, fraud")
        Container(s2, "vertx-server-2", "JVM / Vert.x", "account, loan, notification")
        Container(pyroscope, "Pyroscope", "Grafana Pyroscope", "Continuous profiling backend")
        Container(prometheus, "Prometheus", "v2.53.0", "Metrics TSDB & scraper")
        Container(grafana, "Grafana", "v11.5.2", "Dashboards & visualization")
    }

    Rel(s1, pyroscope, "JFR push (cpu, alloc, lock, wall)")
    Rel(s2, pyroscope, "JFR push (cpu, alloc, lock, wall)")
    Rel(prometheus, s1, "Scrape /metrics :8080 + JMX :9404")
    Rel(prometheus, s2, "Scrape /metrics :8080 + JMX :9404")
    Rel(grafana, pyroscope, "Datasource queries")
    Rel(grafana, prometheus, "Datasource queries")
    Rel(user, grafana, "Browse dashboards :3000")
```

## 2. Application Architecture — Vert.x Shared-JVM Model

### How It Works

`MainVerticle.main()` is the single entry point for every server container:

1. Reads the `VERTICLE` env var (e.g. `main,order,payment,fraud`)
2. Creates a shared Vert.x `Router`
3. Registers `/health` and `/metrics` on the shared router
4. Calls `registerRoutes()` on each requested verticle — all routes are mounted on the **same router**
5. Starts **one HTTP server** on port 8080

All verticles run in the same JVM process, sharing the event loop pool and worker thread pool.

### Internal Structure

```mermaid
flowchart TD
    subgraph JVM["JVM Process (one per container)"]
        EL["Vert.x Event Loop Pool"]
        WT["Worker Thread Pool"]
        R["Shared Router :8080"]
        H["/health"]
        M["/metrics"]

        subgraph V1["Verticle A routes"]
            RA["/order/create"]
            RB["/order/list"]
            RC["..."]
        end

        subgraph V2["Verticle B routes"]
            RD["/payment/transfer"]
            RE["/payment/payroll"]
            RF["..."]
        end

        EL -->|"non-blocking"| R
        R --> H
        R --> M
        R --> V1
        R --> V2
        V1 -->|"executeBlocking()"| WT
        V2 -->|"executeBlocking()"| WT
    end
```

### Verticle-to-Server Mapping

```mermaid
flowchart LR
    subgraph S1["vertx-server-1 :18080"]
        M1["MainVerticle"]
        O1["OrderVerticle"]
        P1["PaymentVerticle"]
        F1["FraudDetectionVerticle"]
    end

    subgraph S2["vertx-server-2 :18081"]
        A2["AccountVerticle"]
        L2["LoanVerticle"]
        N2["NotificationVerticle"]
    end
```

### Why This Matters for Profiling

Pyroscope sees **one application per server**. Flame graphs show mixed code from all verticles on that server — exactly as in production. To identify which verticle owns a hot frame, look at the package/class in the stack:

- `com.example.OrderVerticle` → Order verticle
- `com.example.PaymentVerticle` → Payment verticle
- `com.example.handlers.*` → MainVerticle enterprise simulation handlers

## 3. Verticle Catalog

| Verticle | Server | Route Prefix | Key Routes | Profile Characteristics |
|----------|--------|-------------|------------|------------------------|
| **MainVerticle** | 1 | `/cpu`, `/alloc`, `/slow`, `/db`, `/mixed`, `/sim/*` | `/cpu` (fibonacci), `/alloc` (buffer churn), `/slow` (sleep), `/sim/redis`, `/sim/db`, `/sim/csv` | CPU, alloc, wall |
| **OrderVerticle** | 1 | `/order/*` | `/order/create`, `/order/process`, `/order/validate`, `/order/aggregate`, `/order/fulfill` | CPU (string parsing, regex), alloc (HashMap), lock (synchronized) |
| **PaymentVerticle** | 1 | `/payment/*` | `/payment/transfer`, `/payment/payroll`, `/payment/fx`, `/payment/reconcile` | CPU (BigDecimal, SHA-256), alloc (ledger), lock (synchronized writes), wall (fan-out) |
| **FraudDetectionVerticle** | 1 | `/fraud/*` | `/fraud/score`, `/fraud/scan`, `/fraud/anomaly`, `/fraud/velocity` | CPU (regex, statistics), alloc (sliding window), wall (large dataset sort) |
| **AccountVerticle** | 2 | `/account/*` | `/account/open`, `/account/deposit`, `/account/withdraw`, `/account/statement`, `/account/interest` | CPU (BigDecimal loops), alloc (ConcurrentHashMap), lock (synchronized deposit/withdraw) |
| **LoanVerticle** | 2 | `/loan/*` | `/loan/apply`, `/loan/amortize`, `/loan/risk-sim`, `/loan/portfolio`, `/loan/originate` | CPU (amortization, Monte Carlo), alloc (BigDecimal objects), wall (orchestration) |
| **NotificationVerticle** | 2 | `/notify/*` | `/notify/send`, `/notify/bulk`, `/notify/drain`, `/notify/render`, `/notify/retry` | CPU (queue drain), alloc (template rendering), wall (exponential backoff) |

## 4. Deployment Architecture

### Docker Compose Topology

```mermaid
flowchart TB
    subgraph net["Network: monitoring (bridge)"]
        subgraph infra["Observability Infrastructure"]
            PY["pyroscope\n:4040\nmem: 2 GB\nvolume: pyroscope-data"]
            PR["prometheus\n:9090\nmem: 1 GB\nvolume: prometheus-data"]
            GR["grafana\n:3000\nmem: 512 MB\nvolume: grafana-data"]
        end

        subgraph apps["Application Servers"]
            S1["vertx-server-1\n:18080 → 8080\n:9404 (JMX)\nmem: 768 MB"]
            S2["vertx-server-2\n:18081 → 8080\n:9404 (JMX)\nmem: 768 MB"]
        end
    end

    S1 -->|"depends_on healthy"| PY
    S2 -->|"depends_on healthy"| PY
    GR -->|"depends_on healthy"| PR
    GR -->|"depends_on healthy"| PY
```

### Port Assignment

All host ports are configurable via environment variables with defaults in `docker-compose.yaml`:

| Service | Host Port Variable | Default | Container Port |
|---------|-------------------|---------|----------------|
| Pyroscope | `PYROSCOPE_PORT` | 4040 | 4040 |
| Prometheus | `PROMETHEUS_PORT` | 9090 | 9090 |
| Grafana | `GRAFANA_PORT` | 3000 | 3000 |
| vertx-server-1 | `VERTX_SERVER_1_PORT` | 18080 | 8080 |
| vertx-server-2 | `VERTX_SERVER_2_PORT` | 18081 | 8080 |

`scripts/deploy.sh` auto-resolves port conflicts by scanning used ports and writing overrides to `.env`.

### Container Configuration

| Service | `mem_limit` | Health Check | `depends_on` |
|---------|------------|-------------|--------------|
| pyroscope | 2 GB | `curl /ready` | — |
| prometheus | 1 GB | `curl /-/ready` | — |
| grafana | 512 MB | `curl /api/health` | prometheus (healthy), pyroscope (healthy) |
| vertx-server-1 | 768 MB | `curl /health` | pyroscope (healthy) |
| vertx-server-2 | 768 MB | `curl /health` | pyroscope (healthy) |

## 5. Observability Data Flow

```mermaid
flowchart LR
    subgraph JVM1["vertx-server-1"]
        PA1["Pyroscope Agent\n(JFR push)"]
        JMX1["JMX Exporter\n:9404"]
        MM1["Vert.x Micrometer\n:8080/metrics"]
    end

    subgraph JVM2["vertx-server-2"]
        PA2["Pyroscope Agent\n(JFR push)"]
        JMX2["JMX Exporter\n:9404"]
        MM2["Vert.x Micrometer\n:8080/metrics"]
    end

    PY["Pyroscope\n:4040"]
    PR["Prometheus\n:9090"]

    PA1 -->|"push profiles"| PY
    PA2 -->|"push profiles"| PY
    PR -->|"scrape /metrics"| MM1
    PR -->|"scrape /metrics"| MM2
    PR -->|"scrape :9404"| JMX1
    PR -->|"scrape :9404"| JMX2

    subgraph GR["Grafana :3000"]
        DS1["Pyroscope\ndatasource"]
        DS2["Prometheus\ndatasource"]
        D1["Pyroscope — Production Debugging"]
        D2["Service Comparison"]
        D3["JVM Metrics"]
        D4["HTTP Performance"]
        D5["Verticle Performance"]
        D6["D5: Before vs After Fix"]
    end

    PY --> DS1
    PR --> DS2
    DS1 --> D1
    DS1 --> D2
    DS1 --> D5
    DS2 --> D3
    DS2 --> D4
    DS2 --> D5
    DS1 --> D6
```

### Three Telemetry Pipelines

| Pipeline | Agent | Transport | Backend | What It Captures |
|----------|-------|-----------|---------|-----------------|
| **Continuous Profiling** | Pyroscope Java agent (JFR) | Push to `:4040` | Pyroscope | CPU, alloc, lock, wall flame graphs |
| **JVM Metrics** | JMX Exporter agent (`:9404`) | Prometheus scrape | Prometheus | Heap, GC, threads, CPU, classloading |
| **Application Metrics** | Vert.x Micrometer (`:8080/metrics`) | Prometheus scrape | Prometheus | HTTP request rate, latency, status codes |

### Reading Mixed Flame Graphs

Since multiple verticles share a JVM, flame graphs show interleaved stacks. To isolate verticle behavior:

1. **By class name** — look for `com.example.OrderVerticle`, `com.example.PaymentVerticle`, etc. in the stack
2. **By route handler** — Vert.x router frames will show the registered path
3. **By Pyroscope labels** — the `server` label (`vertx-server-1` / `vertx-server-2`) identifies which group of verticles is running

## 6. Configuration Reference

### JAVA_TOOL_OPTIONS Breakdown

Each Vert.x server container sets `JAVA_TOOL_OPTIONS` with two Java agents:

```
# Pyroscope agent — continuous profiling via JFR
-javaagent:/opt/pyroscope/pyroscope.jar
-Dpyroscope.application.name=vertx-server-1       # Application name in Pyroscope UI
-Dpyroscope.server.address=http://pyroscope:4040   # Push target
-Dpyroscope.format=jfr                             # JDK Flight Recorder format
-Dpyroscope.profiler.event=itimer                   # CPU profiling event (alloc/lock enabled by their own flags)
-Dpyroscope.profiler.alloc=512k                    # Allocation sampling interval
-Dpyroscope.profiler.lock=10ms                     # Lock contention threshold
-Dpyroscope.labels.env=production                  # Static label
-Dpyroscope.labels.server=vertx-server-1           # Static label for filtering
-Dpyroscope.log.level=info

# JMX Exporter — JVM metrics as Prometheus endpoint
-javaagent:/opt/jmx-exporter/jmx_prometheus_javaagent.jar=9404:/opt/jmx-exporter/config.yaml
```

### OPTIMIZED Environment Variable

Toggles between deliberately slow and optimized code paths for before/after flame graph comparison:

| Value | Behavior |
|-------|----------|
| `true` | Use optimized implementations (iterative fibonacci, ThreadLocal MessageDigest, lock-free processing, primitive arrays, StringBuilder templates) |
| unset or other | Use original slow implementations (recursive fibonacci, synchronized blocks, per-call getInstance, boxed collections, String.format) |

Set via `docker-compose.fixed.yaml` override or `--fixed` flag in `scripts/run.sh`. The default pipeline runs both phases automatically.

### VERTICLE Environment Variable

Comma-separated list of verticle names to deploy on this server:

| Value | Behavior |
|-------|----------|
| `main,order,payment,fraud` | Deploy those four verticles |
| `account,loan,notification` | Deploy those three verticles |
| `all` | Deploy all seven verticles |
| `main` (default) | Deploy MainVerticle only |

Valid names: `main`, `order`, `payment`, `fraud`, `account`, `loan`, `notification`.

### Docker Compose Services

| Service | Image | Build | Volumes |
|---------|-------|-------|---------|
| pyroscope | `grafana/pyroscope:latest` | — | `pyroscope-data:/data`, `config/pyroscope/pyroscope.yaml` |
| prometheus | `prom/prometheus:v2.53.0` | — | `prometheus-data:/prometheus`, `config/prometheus/prometheus.yaml`, `alerts.yaml` |
| grafana | `grafana/grafana:11.5.2` | — | `grafana-data:/var/lib/grafana`, provisioning config, dashboard JSONs |
| vertx-server-1 | — | `./sample-app/Dockerfile` | — |
| vertx-server-2 | — | `./sample-app/Dockerfile` | — |
