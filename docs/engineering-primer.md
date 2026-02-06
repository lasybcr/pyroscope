# Continuous Profiling with Grafana Pyroscope — Engineering Primer

## Table of Contents

1. [What Problem Does This Solve](#what-problem-does-this-solve)
2. [What is Continuous Profiling](#what-is-continuous-profiling)
3. [How It Differs from Metrics, Logs, and Traces](#how-it-differs-from-metrics-logs-and-traces)
4. [What is Grafana Pyroscope](#what-is-grafana-pyroscope)
5. [Java-Specific Continuous Profiling](#java-specific-continuous-profiling)
6. [Comparison to Dynatrace](#comparison-to-dynatrace)
7. [Deployment Modes](#deployment-modes)
8. [Improving Incident Response and MTTR](#improving-incident-response-and-mttr)
9. [Business Value](#business-value)
10. [Security and Compliance Considerations](#security-and-compliance-considerations)
11. [Limitations and Trade-offs](#limitations-and-trade-offs)
12. [Getting Started](#getting-started)
13. [Glossary](#glossary)

---

## What Problem Does This Solve

When a production service is slow, the standard investigation looks like this:

1. Alert fires: "Service 1 p99 latency > 2s"
2. Check metrics — CPU is high, but which code path?
3. Check logs — nothing obvious, the service isn't erroring, just slow
4. Check traces — the span is slow, but the trace shows time spent "in the service," not which function
5. Guess — "maybe it's the database query?" → add logging, redeploy, wait for recurrence
6. Repeat until you find it or the problem goes away on its own

The gap is between steps 3 and 4. Metrics tell you **what** resource is saturated. Traces tell you **where** in the call chain the time is spent between services. But neither tells you **which function inside the service** is responsible.

Continuous profiling fills this gap. It records which functions consume CPU, allocate memory, and contend on locks — always on, low overhead — so when an incident occurs, the data is already there.

---

## What is Continuous Profiling

Continuous profiling is the practice of **always-on, low-overhead sampling** of what code is executing in production. At regular intervals (typically every 10ms), the profiler captures a stack trace — the chain of function calls currently on the CPU. Over millions of samples, this produces a statistical picture of where time and resources are spent.

```mermaid
graph LR
    subgraph Traditional Profiling
        A[Developer attaches profiler] --> B[Reproduce issue in staging]
        B --> C[Collect samples for 5 minutes]
        C --> D[Analyze locally]
    end

    subgraph Continuous Profiling
        E[Agent runs in production 24/7] --> F[Samples sent to server every 10s]
        F --> G[Query any time range retroactively]
        G --> H[Compare before vs after any change]
    end

    style A fill:#ef4444,color:#fff
    style E fill:#22c55e,color:#fff
```

Differences from traditional profiling:

| Aspect | Traditional | Continuous |
|--------|------------|------------|
| When it runs | Manually attached during debugging | Always on, in production |
| Where it runs | Staging, developer laptop | Production |
| Data availability | Only while attached | Historical — query any past time window |
| Overhead | 5-20% (too high for production) | < 1% (production-safe) |
| Comparison | Single snapshot | Compare any two time ranges (before/after deploy) |

The output is a **flame graph** — a visualization where the x-axis is proportional to time spent and the y-axis shows the call stack. Wide bars mean that function (and everything it calls) is consuming significant resources.

```
Example flame graph (text representation):

  ┌──────────────────────────────────────────────────────────┐
  │                     main()                                │
  ├────────────────────────────┬─────────────────────────────┤
  │     handleRequest()        │      processQueue()          │
  ├──────────┬─────────────────┤                              │
  │ validate │  computeHash()  │                              │
  │  Input() │  ████████████   │                              │
  │          │  (THIS is your  │                              │
  │          │   bottleneck)   │                              │
  └──────────┴─────────────────┴─────────────────────────────┘
```

---

## How It Differs from Metrics, Logs, and Traces

Standard observability covers metrics, logs, and traces. Profiling adds a fourth signal:

```mermaid
graph TB
    subgraph The Four Pillars of Observability
        M[Metrics<br/><i>Prometheus</i>]
        L[Logs<br/><i>Loki / ELK</i>]
        T[Traces<br/><i>Jaeger / Tempo</i>]
        P[Profiles<br/><i>Pyroscope</i>]
    end

    INCIDENT[Production Incident] --> M
    INCIDENT --> L
    INCIDENT --> T
    INCIDENT --> P

    M --> |"WHAT is wrong<br/>(CPU high, latency up)"| ANSWER
    L --> |"WHEN did it start<br/>(error messages, timestamps)"| ANSWER
    T --> |"WHERE in the call chain<br/>(which service, which span)"| ANSWER
    P --> |"WHY is it slow<br/>(which function, which line)"| ANSWER

    ANSWER[Root Cause]

    style P fill:#f59e0b,color:#000
```

| Pillar | Question it answers | Granularity | Example |
|--------|-------------------|-------------|---------|
| **Metrics** | Is something wrong? | Service-level counters and gauges | "CPU is at 95% on Service 1" |
| **Logs** | What happened? | Individual events with text | "ERROR: Timeout connecting to database" |
| **Traces** | Where is time spent across services? | Per-request call chain | "200ms in Service 1, 50ms in Service 2" |
| **Profiles** | Why is this specific code slow? | Per-function CPU/memory/lock usage | "computeHash() takes 73% of CPU due to SHA-256 in a loop" |

Without profiling, you know the service is slow (metrics) and the request spent 200ms there (traces), but not whether it's the hash computation, the database query, or the serialization. With profiling, you open the flame graph and see which function.

---

## What is Grafana Pyroscope

Grafana Pyroscope is an open-source continuous profiling database. It stores profiling data, lets you query any time range, and integrates with Grafana for visualization alongside metrics and traces.

```mermaid
graph TB
    subgraph Your Applications
        APP1[Service 1<br/>Java]
        APP2[Service 2<br/>Java]
        APP3[Service 3<br/>Java]
    end

    subgraph Pyroscope
        PUSH[Push API<br/>:4040/ingest]
        STORE[(Block Storage<br/>filesystem or S3)]
        QUERY[Query API]
    end

    APP1 -->|"profiles every 10s"| PUSH
    APP2 -->|"profiles every 10s"| PUSH
    APP3 -->|"profiles every 10s"| PUSH
    PUSH --> STORE
    QUERY --> STORE

    GF[Grafana] -->|"render flame graph<br/>for time range"| QUERY
    ENG[Engineer] -->|"open dashboard<br/>during incident"| GF
```

Grafana Labs acquired Pyroscope in 2023. It's part of the same stack as Prometheus/Mimir, Loki, and Tempo, so flame graphs render natively in Grafana dashboards alongside metrics panels.

### Capabilities

- Multi-language: Java, Go, Python, .NET, Ruby, Node.js, Rust, eBPF
- Profile types: CPU, allocation, lock contention, wall clock, goroutines (Go)
- Diff view: compare two time ranges to see what changed after a deploy
- Label-based querying: filter by service, environment, version, custom labels
- Grafana-native: flame graph panel type, Pyroscope datasource plugin
- Low overhead: < 1% CPU (async-profiler for Java)

---

## Java-Specific Continuous Profiling

### How Java profiling works under the hood

Java profiling uses **async-profiler**, an open-source sampling profiler for the JVM. It works by using OS-level signals (`SIGPROF` on Linux) and the JVM's `AsyncGetCallTrace` API to capture stack traces without stop-the-world pauses.

```mermaid
sequenceDiagram
    participant OS as Linux Kernel
    participant AP as async-profiler<br/>(native agent)
    participant JVM as JVM
    participant PJ as Pyroscope Java Agent
    participant PS as Pyroscope Server

    loop Every 10ms
        OS->>AP: SIGPROF signal (timer interrupt)
        AP->>JVM: AsyncGetCallTrace()
        JVM-->>AP: Current stack trace
        AP->>AP: Accumulate in ring buffer
    end

    loop Every 10 seconds
        PJ->>AP: Collect accumulated samples
        AP-->>PJ: Folded stack traces
        PJ->>PS: POST /ingest (compressed protobuf)
    end
```

The Pyroscope Java agent wraps async-profiler and handles:
- Attaching at startup via `JAVA_TOOL_OPTIONS` (no code changes)
- Collecting samples on a schedule
- Labeling data (service name, environment, custom tags)
- Shipping data to the Pyroscope server

### Profile types for Java

| Profile Type | What It Measures | When To Use | Common Findings |
|-------------|-----------------|-------------|-----------------|
| **CPU** (`itimer`) | Time spent on-CPU executing instructions | Service is CPU-bound, high CPU usage | Hot loops, expensive computations, regex, serialization |
| **Allocation** (`alloc`) | Heap memory allocated per stack trace | High GC pressure, frequent GC pauses | Object churn, unnecessary copies, boxing/unboxing |
| **Lock** (`lock`) | Time spent waiting to acquire locks | Thread contention, synchronized blocks | `synchronized` methods, `ReentrantLock` waits, connection pool contention |
| **Wall clock** (`wall`) | Real elapsed time including I/O waits | Service is slow but CPU is low | Network I/O, database waits, `Thread.sleep`, file I/O |

### Zero-code attachment

The profiler is attached via an environment variable. No application code, no dependency changes, no rebuild required:

```yaml
environment:
  JAVA_TOOL_OPTIONS: >-
    -javaagent:/opt/pyroscope/pyroscope.jar
    -Dpyroscope.application.name=app-service-1
    -Dpyroscope.server.address=http://pyroscope:4040
    -Dpyroscope.format=jfr
    -Dpyroscope.profiler.event=itimer
    -Dpyroscope.profiler.alloc=512k
    -Dpyroscope.profiler.lock=10ms
```

No code change or rebuild needed — set the environment variable and restart.

### JVM version compatibility

| JVM | Support | Notes |
|-----|---------|-------|
| OpenJDK 8+ | Full | Most common in enterprise |
| Oracle JDK 8+ | Full | Same internals as OpenJDK |
| Eclipse Temurin 11+ | Full | Adoptium distribution of OpenJDK |
| GraalVM | Partial | CPU profiling works, allocation profiling limited |
| IBM J9 / Semeru | Limited | Different JVM internals, some profile types unavailable |

---

## Comparison to Dynatrace

**Choose Pyroscope when:**
- You need on-premises deployment (air-gapped, regulated, private cloud)
- You already use the Grafana stack (Prometheus, Loki, Tempo)
- You want flame graphs next to metrics and traces in the same Grafana dashboard
- Budget is constrained — it's free and open source
- You need to keep profiling data on your own infrastructure (data sovereignty)

**Choose Dynatrace when:**
- You want a fully managed, all-in-one observability platform
- You need automatic root cause analysis powered by Dynatrace's AI (Davis)
- Your organization already has a Dynatrace license
- You need automatic instrumentation discovery (Dynatrace OneAgent auto-detects services)
- Budget is available — Dynatrace is premium priced but reduces operational burden

### Dynatrace vs Pyroscope — deep comparison

| Dimension | Pyroscope | Dynatrace |
|-----------|-----------|-----------|
| **Deployment** | Self-hosted (you run it) | SaaS or Managed (Dynatrace runs it, or on-prem with Dynatrace Managed) |
| **Data residency** | Your infrastructure — you control where data lives | Dynatrace cloud (US/EU regions) or your infrastructure (Managed) |
| **Auto-instrumentation** | Agent must be explicitly attached via `JAVA_TOOL_OPTIONS` | OneAgent auto-discovers and instruments all processes on a host |
| **Root cause analysis** | Manual — engineer reads the flame graph | Automated — Davis AI correlates metrics, traces, and profiles to suggest root cause |
| **Cost at scale (100 hosts)** | Infrastructure cost only (~$0/month for software, NFS/compute costs) | ~$5,000-7,000/month |
| **Operational burden** | You maintain the Pyroscope server, storage, upgrades | Dynatrace handles it (SaaS) or significantly reduces it (Managed) |
| **Grafana integration** | Native — flame graphs in Grafana dashboards | Requires separate Dynatrace UI or API integration |
| **Vendor lock-in** | None — open source, standard data formats | High — proprietary agent, API, and data format |
| **PCI/SOX compliance** | You own the audit trail | Dynatrace provides compliance certifications for their cloud |

In practice: teams with existing Dynatrace contracts keep using Dynatrace. Teams building a new stack, running on-prem, or watching costs go with Pyroscope + Grafana.

---

## Deployment Modes

Pyroscope supports two deployment modes. Use monolithic mode for development, POC, and evaluation. Plan on microservices mode for production.

### Monolithic mode (dev / POC / evaluation)

A single Pyroscope process handles ingestion, storage, and querying. This is the fastest way to get running and evaluate the tool. The diagram below shows how Pyroscope integrates with an existing Grafana and Prometheus deployment:

```mermaid
graph TB
    subgraph Enterprise Network
        subgraph Application Servers
            S1[Service 1<br/>Java + Pyroscope Agent]
            S2[Service 2<br/>Java + Pyroscope Agent]
            S3[Service 3<br/>Java + Pyroscope Agent]
        end

        subgraph Pyroscope VM
            PY[Pyroscope Server<br/>:4040]
            FS[("/data<br/>local filesystem")]
            PY --> FS
        end

        subgraph Existing Monitoring
            GF[Grafana :3000<br/>already deployed]
            PR[Prometheus :9090<br/>already deployed]
        end
    end

    S1 -->|push profiles| PY
    S2 -->|push profiles| PY
    S3 -->|push profiles| PY

    GF -->|query profiles<br/>new datasource| PY
    GF -->|query metrics<br/>existing| PR
    PR -->|scrape /metrics| S1
    PR -->|scrape /metrics| S2
```

### Microservices mode (production)

For production workloads, Pyroscope's components (distributor, ingester, compactor, store-gateway, query-frontend, query-scheduler, querier, overrides-exporter, and optional ruler) run as separate processes with shared object storage. This provides high availability, horizontal scalability, and independent scaling of read and write paths. See `deploy/microservices/README.md` for the full production deployment guide.

### Choosing a mode

| Factor | Monolithic | Microservices |
|--------|-----------|---------------|
| Purpose | Dev, POC, evaluation | Production |
| Services profiled | Up to ~50 | 50+ or high-throughput |
| Ingestion rate | < 100 MB/s | Hundreds of MB/s |
| Availability | Single point of failure | Highly available |
| Operational complexity | Minimal — one process | Higher — 9 services, shared storage |

Start with monolithic mode to evaluate Pyroscope and validate the integration. When moving to production, deploy in microservices mode for high availability and scalability.

### Integration steps

1. **Deploy Pyroscope server on a VM** — use the scripts in `deploy/monolithic/` for dev/POC
2. **Upload the Pyroscope Java agent JAR to Artifactory** — download from [Grafana Pyroscope releases](https://github.com/grafana/pyroscope-java/releases) and publish to your internal artifact repository so builds can pull it without external access
3. **Update the Docker image** — add a `COPY` or dependency-fetch step in the Dockerfile to include the agent JAR at a known path (e.g., `/opt/pyroscope/pyroscope.jar`). Alternatively, mount the JAR into the container via a Docker volume at runtime.
4. **Add the agent to your application startup command** — set `-javaagent:/opt/pyroscope/pyroscope.jar` and the required system properties in `JAVA_TOOL_OPTIONS` or your entrypoint:
   ```
   -javaagent:/opt/pyroscope/pyroscope.jar
   -Dpyroscope.application.name=app-service-1
   -Dpyroscope.server.address=http://<pyroscope-host>:4040
   -Dpyroscope.format=jfr
   -Dpyroscope.profiler.event=itimer
   -Dpyroscope.profiler.alloc=512k
   -Dpyroscope.profiler.lock=10ms
   ```
5. **Add Pyroscope as a data source in Grafana** — point Grafana at `http://<pyroscope-host>:4040` and use the built-in flame graph panel

### Storage sizing

Pyroscope's storage needs depend on the number of services profiled, the number of profile types, and retention period:

| Variable | Our Setup |
|----------|-----------|
| Services profiled | 9 |
| Profile types per service | 4 (CPU, alloc, lock, wall) |
| Ingestion rate (approximate) | ~5 MB/min |
| Daily storage | ~7 GB |
| 30-day retention | ~210 GB |
| Recommended disk | 500 GB (with headroom for compaction) |

---

## Improving Incident Response and MTTR

### The traditional incident workflow

```mermaid
graph TD
    A[Alert: p99 > 2s] --> B[Check Grafana dashboards]
    B --> C{Obvious from metrics?}
    C -->|No| D[Check logs for errors]
    D --> E{Error found?}
    E -->|No| F[Add debug logging]
    F --> G[Redeploy to production]
    G --> H[Wait for recurrence]
    H --> I[Read new logs]
    I --> J{Root cause found?}
    J -->|No| F
    J -->|Yes| K[Fix and deploy]

    style F fill:#ef4444,color:#fff
    style G fill:#ef4444,color:#fff
    style H fill:#ef4444,color:#fff
```

Each "add logging → redeploy → wait → read" cycle takes 30 minutes to hours. Most incidents need 2-4 cycles. The "wait for recurrence" step is the worst for intermittent issues.

### The profiling-informed workflow

```mermaid
graph TD
    A[Alert: p99 > 2s] --> B[Check Grafana dashboards]
    B --> C[Open flame graph for affected service<br/>filter to alert time window]
    C --> D[Identify widest frame = biggest CPU consumer]
    D --> E[Read the function name and source location]
    E --> F[Fix and deploy]

    style C fill:#22c55e,color:#fff
    style D fill:#22c55e,color:#fff
```

No "add logging" step. The agent was running the whole time. Query the incident's time range and the flame graph shows you the answer.

### MTTR impact by incident type

| Incident Type | Without Profiling | With Profiling | Why |
|--------------|:-:|:-:|---|
| **CPU spike** | 1-4 hours (guess which code path) | 5-15 minutes (flame graph shows the function) | No guessing — the hot function is the widest bar |
| **Memory leak / GC pressure** | 2-8 hours (add heap dumps, wait for recurrence) | 15-30 minutes (allocation flame graph shows which function allocates most) | Allocation profile is always on — no need to reproduce |
| **Lock contention** | 2-6 hours (thread dumps, timing analysis) | 10-20 minutes (lock flame graph shows the contended lock) | Lock profiling captures contention continuously |
| **Latency regression after deploy** | 1-4 hours (compare logs, bisect commits) | 5-10 minutes (diff flame graph: before deploy vs after) | Diff view highlights exactly what changed |
| **Intermittent slowness** | Days (wait for recurrence with logging enabled) | Minutes (query the time window when it happened) | Data is retroactive — the profile was captured when the issue occurred |

### Concrete example

**Scenario**: A service's p99 spikes from 200ms to 3s every day around 2pm.

**Without profiling** (3 days to resolve):
- Day 1: Notice the pattern in metrics. Add timing logs around the main code paths. Redeploy.
- Day 2: Logs show time is spent in `processBatch()` but not which part. Add more granular logging inside that method. Redeploy.
- Day 3: Finally see that `computeHash()` is called 500 times per batch, each doing `MessageDigest.getInstance("SHA-256")` which is expensive. Fix: cache the MessageDigest instance.

**With profiling** (15 minutes to resolve):
- Open Grafana, filter to the affected service, CPU profile, 1:50pm-2:10pm today
- Flame graph shows `processBatch()` → `computeHash()` → `MessageDigest.getInstance()` consuming 73% of CPU
- Fix: cache the MessageDigest instance

Same root cause, same fix. 3 days vs 15 minutes.

---

## Business Value

### Engineering time savings

| Metric | Before | After |
|--------|--------|-------|
| MTTR for performance incidents | 3-6 hours | 15-45 minutes |
| Debug cycles per incident (add logging → redeploy → wait) | 2-4 cycles | 0 |
| Incidents requiring staging reproduction | ~40% | < 5% |
| Engineering hours on performance debugging per quarter | ~200 hours (est.) | ~40 hours |

### Infrastructure cost optimization

Profiling shows where CPU cycles go, so you can optimize code instead of adding pods:

- "The service needs 8 pods" → profile shows 60% of CPU in an unoptimized hash function → fix it → 3 pods is enough
- "We need bigger instances for the loan service" → profile shows Monte Carlo sim allocates too many temp objects → reduce allocations → same instance size works

### Risk reduction

- Faster resolution = shorter customer-facing impact
- Retroactive data = no "we need to wait for it to happen again"
- Before/after deploy comparison = catch regressions before they hit production
- No code changes = can roll out to any Java service immediately

---

## Security and Compliance

| Concern | Assessment |
|---------|------------|
| **Does the profiler see application data?** | No. It captures function names and call stacks only — it does not inspect variables, method arguments, or return values. No PII, no credentials, no customer data. |
| **What data is sent to the Pyroscope server?** | Stack traces (function names), sample counts, and labels (service name, environment). Not business data. |
| **Does it affect application behavior?** | No. Sampling is passive — it reads the call stack, it does not modify execution. The agent does not inject bytecode or alter class loading (unlike some APM agents). |
| **Network communication** | Agent pushes data to Pyroscope over HTTP. Can be configured for HTTPS. All traffic stays within the enterprise network (no external calls). |
| **Data at rest** | Profile data is stored on the Pyroscope server's filesystem. Encryption at rest depends on the underlying storage (encrypted NFS, encrypted EBS, etc.). |
| **Access control** | Grafana's role-based access control governs who can view flame graphs. Pyroscope itself does not have built-in auth — it relies on network-level access control or a reverse proxy. |
| **Overhead** | < 1% CPU, negligible memory. Benchmarked with our services — see the `benchmark.sh` script in the repo. |

---

## Limitations and Trade-offs

**What continuous profiling does NOT do:**

- It does not replace APM distributed tracing — profiling shows function-level detail within one service, traces show the call chain across services. They're complementary.
- It does not capture per-request profiles — it's statistical sampling. You see "this function uses 30% of CPU across all requests," not "this specific request was slow because of this function."
- It does not profile database queries — if your service is slow because the database is slow, the flame graph shows time in the JDBC driver's `read()` call. You still need database monitoring to understand why the query is slow.
- It does not automatically fix anything — it shows you the problem. A human still needs to understand the code and write the fix.

**Operational considerations:**

- Pyroscope server in monolithic mode is a single point of failure. If it goes down, profile data is not collected until it recovers. Applications are not affected (the agent silently drops data if the server is unreachable).
- Storage grows linearly with the number of services and profile types. Plan disk capacity accordingly.
- The Pyroscope Java agent is based on async-profiler, which requires the `perf_event_open` syscall. In containerized environments, the container must have the `SYS_PTRACE` capability or the host must set `kernel.perf_event_paranoid <= 1`.

---

## Getting Started

For hands-on setup, deployment scripts, and operational runbooks, refer to the project repository:

| What you need | Where to find it |
|--------------|-----------------|
| Run the full demo stack locally | Repository README — Quick Start section |
| Understand the service architecture | `docs/architecture.md` |
| Step-by-step demo for stakeholders | `docs/demo-runbook.md` |
| Hands-on profiling investigation scenarios | `docs/profiling-scenarios.md` |
| Source code to flame graph mapping | `docs/code-to-profiling-guide.md` |
| Grafana dashboard reference | `docs/dashboard-guide.md` |
| Deploy Pyroscope server to a VM | `deploy/monolithic/README.md` |
| Deploy Pyroscope microservices (NFS) | `deploy/microservices/README.md` |
| Incident response playbooks | `docs/runbook.md` |
| MTTR reduction workflow | `docs/mttr-guide.md` |

---

## Glossary

| Term | Definition |
|------|-----------|
| **Flame graph** | A visualization of profiling data. The x-axis represents time proportion, the y-axis represents the call stack. Wider bars = more time spent in that function. |
| **async-profiler** | An open-source low-overhead sampling profiler for the JVM. It uses OS-level interrupts to capture stack traces without stopping the application. |
| **JFR (Java Flight Recorder)** | A JVM built-in profiling and event recording framework. Pyroscope can use JFR as its data format. |
| **Sampling** | The profiling technique of periodically recording the current call stack rather than instrumenting every function call. Sampling has negligible overhead because it only looks at the state every N milliseconds. |
| **Profile type** | The category of resource being profiled: CPU (compute time), allocation (memory), lock (contention), or wall (real elapsed time). |
| **Ingestion** | The process of receiving profile data from application agents and writing it to storage. |
| **Retention** | How long profile data is kept before being deleted. Typically 7-30 days. |
| **MTTR** | Mean Time to Resolution — the average time from alert firing to incident resolution. |
| **Continuous profiling** | Always-on profiling in production, as opposed to ad-hoc profiling during debugging sessions. |
