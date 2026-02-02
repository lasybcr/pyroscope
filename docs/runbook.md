# Operations Runbook

Deployment, operations, incident response, and troubleshooting for the Pyroscope continuous profiling stack.

---

## Prerequisites

| Requirement | Minimum | Recommended |
|-------------|---------|-------------|
| Docker | 20.10+ | 24+ |
| Docker Compose | v2 | v2.20+ |
| RAM | 8 GB | 16 GB |
| Disk | 4 GB | 10 GB |

Ports are assigned dynamically and written to `.env` by the deploy script. The run script banner prints the actual URLs after deploy.

---

## Deployment

### Bash Scripts

```bash
# Full pipeline (quiet mode with progress spinner)
bash scripts/run.sh

# Verbose output
bash scripts/run.sh --verbose

# Save logs to disk
bash scripts/run.sh --log-dir /tmp/pyroscope-logs

# Custom load duration (default 120s)
bash scripts/run.sh --load-duration 60

# Individual stages
bash scripts/run.sh deploy
bash scripts/run.sh load 120
bash scripts/run.sh validate

# Tear down
bash scripts/run.sh teardown
```

Sub-scripts can be called directly:

```bash
bash scripts/deploy.sh
bash scripts/generate-load.sh
bash scripts/validate.sh
bash scripts/teardown.sh
```

---

## Verification

### Automated

```bash
bash scripts/validate.sh
```

Checks: all 10 containers running (7 services + Pyroscope + Prometheus + Grafana), Prometheus scraping all targets, alert rules loaded, 5 dashboards provisioned, both datasources active, Pyroscope receiving profiles, all service endpoints responding.

### Manual

```bash
# Container status
docker compose ps

# Pyroscope has profile data
curl -s 'http://localhost:4040/pyroscope/label-values?label=service_name' | python3 -m json.tool

# Prometheus scrape targets
curl -s 'http://localhost:9090/api/v1/targets' | python3 -c "
import sys, json
data = json.load(sys.stdin)
for t in data['data']['activeTargets']:
    print(f\"  {t['labels'].get('job','?'):30} {t['labels'].get('instance','?'):25} {t['health']}\")"

# Grafana dashboards
curl -sf -u admin:admin 'http://localhost:3000/api/search?type=dash-db' | python3 -c "
import sys, json
for d in json.load(sys.stdin):
    print(f\"  {d['uid']:30} {d['title']}\")"
```

Replace `localhost:<port>` with the values from `.env` if ports were reassigned.

---

## Day-to-Day Operations

### Start / Stop

```bash
docker compose up -d                                    # start (no rebuild)
docker compose stop                                     # stop (keep data)
docker compose down -v                                  # stop + delete volumes
docker compose build --parallel && docker compose up -d # rebuild + restart
```

### Logs

```bash
docker compose logs -f                                  # all services
docker compose logs -f bank-api-gateway                 # one service
docker compose logs --since 5m 2>&1 | grep -iE "error|exception|fatal"
```

### Restart a Service

```bash
docker compose restart <service-name>
```

### Generate Load

```bash
# Parallel load generators (300s each)
for i in 1 2 3; do
  bash scripts/generate-load.sh 300 &
done
```

---

## Identifying Performance Hotspots

### Dashboard Approach

The **Pyroscope Java Overview** dashboard (`pyroscope-java-overview`) provides flame graphs for three profile types:

| Profile type | Metric | What it shows |
|-------------|--------|---------------|
| CPU | `process_cpu:cpu:nanoseconds` | Time on CPU per method |
| Memory allocation | `memory:alloc_in_new_tlab_bytes` | Bytes allocated per method |
| Mutex contention | `mutex:contentions:count` | Lock wait events per method |

The **Top Functions (CPU)** table panel ranks functions by self-time, giving a flat view of the hottest methods without needing to read the flame graph.

### CLI Approach

```bash
# Top functions across all services
bash scripts/run.sh top cpu
bash scripts/run.sh top memory
bash scripts/run.sh top mutex

# Single service
bash scripts/top-functions.sh cpu bank-api-gateway
bash scripts/top-functions.sh memory bank-notification-service
bash scripts/top-functions.sh mutex bank-order-service

# Full diagnostic report (health + HTTP + profiles + alerts)
bash scripts/run.sh diagnose
```

### Reading Flame Graphs

```
      +-----------------------------------------+
      |             main() thread                |  <- bottom: entry point
      +--------------------+--------------------+
      |  handleRequest()   |   eventLoop()      |  <- callers
      +---------+----------+                    |
      |compute()| sha256() |                    |  <- top: leaf functions
      +---------+----------+--------------------+
                   WIDTH = TIME SPENT
```

- **X-axis (width):** proportional to time (CPU), bytes (memory), or events (mutex)
- **Y-axis (height):** call stack depth — callers at bottom, callees at top
- **Color:** groups related stacks; no metric meaning
- **Self-time:** time in the function itself, excluding children

| Pattern | Meaning |
|---------|---------|
| Wide bar at the top | Leaf function is the actual hotspot |
| Wide bar in the middle, narrow children | Function is hot because it calls many small functions |
| Very deep stack | Deep recursion or complex call chain |
| Single wide tower | One code path dominates |
| Flat plateau | Many functions each consuming a small slice — no single hotspot |

**Self-time vs total-time:** `top-functions.sh` reports self-time. A function with high total-time but low self-time is a caller, not a bottleneck. Focus on self-time.

**UI interactions:** click a bar to zoom into that subtree; right-click and Focus to isolate a function and its callers; Sandwich view shows callers above and callees below.

---

## Incident Response Playbooks

### First 30 Seconds — Automated Root Cause

```bash
bash scripts/run.sh bottleneck
```

This correlates JVM health, HTTP latency, and profiling hotspots to output a per-service verdict (CPU-bound, GC-bound, lock-bound, I/O-bound, or healthy) with the exact function and recommended action. See [mttr-guide.md](mttr-guide.md) for the full MTTR workflow.

### First 60 Seconds — Full Diagnostic

```bash
bash scripts/run.sh diagnose
```

| Section | What it tells you | Next step |
|---------|-------------------|-----------|
| JVM HEALTH | Which services have high CPU, heap, GC, threads | Go to that service's playbook below |
| HTTP TRAFFIC | Request rate, error rate, avg latency per service | High errors: check logs. High latency: check profiles |
| PROFILING HOTSPOTS | Top function consuming CPU/memory/mutex per service | You now know the class and method — go to code |
| FIRING ALERTS | Which Prometheus alerts are active | Confirms the symptom |

For one service:

```bash
bash scripts/diagnose.sh --service bank-payment-service
```

JSON for scripting or Slack:

```bash
bash scripts/run.sh diagnose --json | jq .
```

### High CPU

**Alert:** `HighCpuUsage` — process CPU > 80% for 1 minute.

**Steps:**

1. Identify the top CPU functions:
   ```bash
   bash scripts/run.sh top cpu
   bash scripts/top-functions.sh cpu bank-api-gateway
   ```
2. Open Grafana Pyroscope Overview, select the affected service, inspect the CPU flame graph.
3. Determine if the hotspot is application code or JVM internals:

| Flame graph top | Meaning | Action |
|-----------------|---------|--------|
| `com.example.*` | Application code is CPU-bound | Optimize the method |
| `java.util.regex.Pattern` | Regex in a loop | Pre-compile, reduce backtracking |
| `java.math.BigDecimal.*` | Financial calculations | Cache results if possible |
| `java.security.MessageDigest` | Crypto hashing | Batch or offload async |
| `jdk.internal.gc.*` / `G1*` | Garbage collector | Switch to memory profile |
| `io.vertx.core.*` | Event loop blocked | Use `executeBlocking()` |

4. Use comparison view to diff against a known-good baseline.
5. Cross-reference with JVM Metrics dashboard: check GC pause rate and thread count.

**Validate fix:**

```bash
bash scripts/top-functions.sh cpu bank-api-gateway
```

### Memory Leak / GC Pressure

**Alert:** `HighHeapUsage` (heap > 85%) or `HighGcPauseRate` (GC > 50ms/s).

**Steps:**

1. Check heap status:
   ```bash
   bash scripts/run.sh health
   ```
2. Find top allocators:
   ```bash
   bash scripts/run.sh top memory
   bash scripts/top-functions.sh memory bank-notification-service
   ```
3. Interpret the allocation profile:

| What you see | Meaning |
|-------------|---------|
| `String.format` / `StringBuilder.toString` | Heavy string construction |
| `ArrayList.<init>` / `ArrayList.grow` | Collection resizing — pre-size |
| `HashMap.put` / `HashMap.resize` | Map resizing — pre-size |
| `BigDecimal.*` | Financial arithmetic intermediates |
| `byte[]` / `char[]` | Raw buffer allocations — pool candidate |
| `LinkedHashMap.<init>` | Per-request maps — reuse via builder |

4. Determine leak vs normal GC — open JVM Metrics Deep Dive, Heap Memory panel:
   - **Sawtooth** = normal GC
   - **Steadily rising** = probable leak
   - **Flat at max** = OOM imminent, restart immediately

5. If GC is the problem, confirm which generation:
   ```bash
   curl -s 'http://localhost:9090/api/v1/query?query=rate(jvm_gc_collection_seconds_sum{job="jvm"}[2m])' | \
     python3 -c "
   import json, sys
   for r in json.load(sys.stdin)['data']['result']:
       inst = r['metric']['instance'].split(':')[0]
       gc = r['metric'].get('gc', 'unknown')
       val = float(r['value'][1])
       if val > 0.001:
           print(f'  {inst} ({gc}): {val:.4f} s/s')"
   ```
   - Young/Minor GC high = short-lived object churn
   - Old/Major GC high = long-lived objects filling old gen (likely leak)

### Lock Contention

**Symptom:** High latency despite low CPU. Threads piling up.

**Steps:**

1. Check thread counts:
   ```bash
   curl -s 'http://localhost:9090/api/v1/query?query=jvm_threads_current{job="jvm"}' | \
     python3 -c "
   import json, sys
   for r in json.load(sys.stdin)['data']['result']:
       inst = r['metric']['instance'].split(':')[0]
       val = int(float(r['value'][1]))
       flag = ' WARNING' if val > 50 else ''
       print(f'  {inst}: {val} threads{flag}')"
   ```
2. Find contended locks:
   ```bash
   bash scripts/run.sh top mutex
   bash scripts/top-functions.sh mutex bank-order-service
   ```
3. Interpret the mutex profile:

| What you see | Meaning |
|-------------|---------|
| `*.processOrders` / `*.handlePayroll` | Synchronized method — all threads serialize |
| `*.handleDeposit` / `*.handleWithdraw` | Balance update locks — concurrent ops block |
| `java.util.concurrent.locks.*` | Explicit lock contention — check scope |
| `io.vertx.core.impl.*` | Event loop blocked |

4. Verify lock impact on latency:
   ```bash
   bash scripts/diagnose.sh --section http --service bank-order-service
   ```
   High latency + low CPU = lock contention confirmed.

### Latency Spike

**Alert:** `HighLatency` — p99 > 2 seconds for 2 minutes.

**Steps:**

1. Find the slow service and endpoint:
   ```bash
   bash scripts/diagnose.sh --section http
   ```
2. Check all three profile types for the affected service:
   ```bash
   SERVICE=bank-payment-service
   bash scripts/top-functions.sh cpu $SERVICE
   bash scripts/top-functions.sh memory $SERVICE
   bash scripts/top-functions.sh mutex $SERVICE
   ```
3. Use the bottleneck matrix:

| CPU hot | Memory hot | Mutex hot | Diagnosis |
|---------|-----------|-----------|-----------|
| Yes | No | No | CPU-bound — optimize the function |
| No | Yes | No | GC-bound — reduce allocation rate |
| No | No | Yes | Lock-bound — reduce synchronized scope |
| No | No | No | Off-CPU — blocking I/O, downstream call, or sleep |
| Yes | Yes | No | CPU + allocation — heavy computation creating temp objects |
| Yes | No | Yes | CPU + lock — threads spinning while waiting |

4. If off-CPU (nothing in any profile):
   ```bash
   docker compose logs --tail 100 $SERVICE 2>&1 | grep -iE "timeout|connect|refused|error"
   bash scripts/run.sh health
   ```

### Post-Deploy Regression

**Steps:**

1. Capture current state:
   ```bash
   bash scripts/diagnose.sh --json > post-deploy.json
   ```
2. Compare CPU hotspots against pre-deploy baseline:
   ```bash
   jq '.profiles[] | select(.service=="bank-payment-service") | .cpu_top5' pre-deploy.json
   jq '.profiles[] | select(.service=="bank-payment-service") | .cpu_top5' post-deploy.json
   ```
3. Use Pyroscope comparison view:
   - Left panel: time range before deploy
   - Right panel: time range after deploy
   - **Red** bars = consuming more resources after deploy
   - **Green** bars = consuming fewer resources

### Service Down

**Alert:** `ServiceDown` — Prometheus scrape fails for 30 seconds.

```bash
docker compose ps
docker compose logs --tail 50 <service-name>
docker compose exec <service-name> sh -c "curl -sf http://localhost:<internal-port>/health"
docker compose restart <service-name>
```

### Escalation Checklist

Generate the diagnostic JSON and attach it to the incident ticket:

```bash
bash scripts/diagnose.sh --json > incident-$(date +%Y%m%d-%H%M%S).json
```

The file contains JVM health, HTTP traffic stats, top 5 CPU/memory/mutex functions per service, and firing alerts.

**Escalation template:**

```
## Incident Summary
- **Time:** [when it started]
- **Affected service:** [from diagnose output]
- **Symptom:** [CPU/memory/latency/errors]

## Evidence
- **Top CPU function:** [from `top cpu` output]
- **Top memory allocator:** [from `top memory` output]
- **Lock contention:** [from `top mutex` output]
- **Heap status:** [from health output]
- **Error rate:** [from diagnose HTTP section]

## What we've tried
- [list actions taken]

## Diagnostic JSON attached
- incident-YYYYMMDD-HHMMSS.json
```

---

## CLI Tools Reference

### bottleneck

Automated root-cause analysis — correlates health, HTTP, and profiles into a single verdict per service.

```bash
bash scripts/run.sh bottleneck                              # all services
bash scripts/bottleneck.sh --service bank-payment-service   # one service
bash scripts/bottleneck.sh --json                           # JSON for alerting
bash scripts/bottleneck.sh --threshold cpu=0.5              # custom thresholds
```

Verdicts: `CPU-BOUND`, `GC-BOUND`, `MEMORY-PRESSURE`, `LOCK-BOUND`, `IO-BOUND`, `HEALTHY`. See [mttr-guide.md](mttr-guide.md) for the full decision matrix.

### diagnose

Full diagnostic report: health, HTTP traffic, profiling hotspots, and firing alerts.

```bash
bash scripts/run.sh diagnose                             # human-readable
bash scripts/run.sh diagnose --json                      # JSON
bash scripts/diagnose.sh --service bank-api-gateway      # one service
bash scripts/diagnose.sh --section health                # one section
bash scripts/diagnose.sh --section http
bash scripts/diagnose.sh --section profiles
bash scripts/diagnose.sh --section alerts
```

JSON filtering examples:

```bash
# Unhealthy services only
bash scripts/diagnose.sh --json | jq '[.health[] | select(.status != "OK")]'

# Top CPU function per service
bash scripts/diagnose.sh --json | jq '.profiles[] | {service, top_cpu: .cpu_top5[0]}'

# Exit non-zero if any alert is firing (CI gate)
bash scripts/diagnose.sh --json | jq -e '.alerts | length == 0' > /dev/null

# Services with error rate > 1%
bash scripts/diagnose.sh --json | jq '[.http.services[] | select(.err_pct > 1)]'
```

### health

JVM health check against fixed thresholds.

```bash
bash scripts/run.sh health
bash scripts/run.sh health --json
```

| Metric | Warning | Critical |
|--------|---------|----------|
| CPU usage | >= 50% | >= 80% |
| Heap utilization | >= 70% | >= 85% |
| GC time rate | >= 0.03 s/s | >= 0.10 s/s |
| Live threads | >= 50 | >= 100 |

### top

Top functions by self-time for a given profile type.

```bash
bash scripts/run.sh top cpu
bash scripts/run.sh top memory
bash scripts/run.sh top mutex
bash scripts/top-functions.sh cpu bank-api-gateway
bash scripts/top-functions.sh --top 20 --range 30m
```

### Direct API Access

**Prometheus:**

```bash
# CPU rate per service
curl -s 'http://localhost:9090/api/v1/query?query=rate(process_cpu_seconds_total{job="jvm"}[2m])'

# Heap usage
curl -s 'http://localhost:9090/api/v1/query?query=jvm_memory_used_bytes{job="jvm",area="heap"}'

# GC rate
curl -s 'http://localhost:9090/api/v1/query?query=rate(jvm_gc_collection_seconds_sum{job="jvm"}[2m])'

# Thread count
curl -s 'http://localhost:9090/api/v1/query?query=jvm_threads_current{job="jvm"}'

# HTTP request rate
curl -s 'http://localhost:9090/api/v1/query?query=sum+by+(instance)(rate(vertx_http_server_requests_total{job="vertx-apps"}[1m]))'

# Firing alerts
curl -s 'http://localhost:9090/api/v1/alerts'
```

**Pyroscope:**

```bash
# List profiled services
curl -s 'http://localhost:4040/querier.v1.QuerierService/LabelValues' \
  -X POST -H 'Content-Type: application/json' \
  -d '{"name":"service_name"}'

# CPU profile (JSON)
curl -s 'http://localhost:4040/pyroscope/render?query=process_cpu:cpu:nanoseconds:cpu:nanoseconds%7Bservice_name%3D%22bank-api-gateway%22%7D&from=now-1h&until=now&format=json'

# Memory allocation profile
curl -s 'http://localhost:4040/pyroscope/render?query=memory:alloc_in_new_tlab_bytes:bytes:space:bytes%7Bservice_name%3D%22bank-api-gateway%22%7D&from=now-1h&until=now&format=json'

# Mutex contention profile
curl -s 'http://localhost:4040/pyroscope/render?query=mutex:contentions:count:mutex:count%7Bservice_name%3D%22bank-order-service%22%7D&from=now-1h&until=now&format=json'
```

Replace `localhost:<port>` with values from `.env` if ports differ.

### CI/CD Integration

**Gate deploys on health:**

```bash
#!/bin/bash
result=$(bash scripts/diagnose.sh --json --section health)
crits=$(echo "$result" | jq '[.health[] | select(.status == "CRITICAL")] | length')
if [ "$crits" -gt 0 ]; then
  echo "CRITICAL services detected after deploy:"
  echo "$result" | jq '.health[] | select(.status == "CRITICAL") | .service'
  exit 1
fi
```

**Capture baseline profiles:**

```bash
bash scripts/diagnose.sh --json > baseline.json
# ... deploy ...
bash scripts/diagnose.sh --json > after.json
jq '.profiles[] | select(.service == "bank-payment-service") | .cpu_top5' baseline.json
jq '.profiles[] | select(.service == "bank-payment-service") | .cpu_top5' after.json
```

**Periodic health (cron):**

```bash
*/5 * * * * bash /path/to/scripts/diagnose.sh --json --section health | jq '[.health[] | select(.status != "OK")]' >> /var/log/jvm-health.jsonl
```

---

## Measuring Profiling Overhead

Run the benchmark to verify the Pyroscope agent does not materially impact service performance. The script tests every service endpoint twice — with and without the agent — and compares latency and throughput.

### Running the benchmark

```bash
# Default: 200 requests per endpoint, 50 warmup
bash scripts/run.sh benchmark

# More statistical significance
bash scripts/run.sh benchmark 500 100
```

### What it measures

The benchmark runs three phases:

1. **With agent** — starts all services normally (Pyroscope `-javaagent` attached via `JAVA_TOOL_OPTIONS`), warms up each endpoint, then measures avg/p50/p95/p99 latency and requests/sec.
2. **Without agent** — restarts all services using `docker-compose.no-pyroscope.yaml` (clears `JAVA_TOOL_OPTIONS`), repeats the same measurements.
3. **Comparison** — prints overhead percentage per service and saves CSV results to `benchmark-results/`.

### Reading results

The comparison table shows per-service overhead:

```
SERVICE                   WITH (avg)   WITHOUT (avg) OVERHEAD
-------                   ----------   ------------- --------
api-gateway               12.3ms       11.8ms        4.2%
order-service             8.1ms        7.9ms         2.5%
payment-service           15.4ms       14.9ms        3.3%
```

After the run, CSV files are saved to `benchmark-results/` with timestamp prefixes for historical comparison.

### Expected overhead

The Pyroscope JFR agent is designed for production use. Expected ranges with the current configuration:

| Profile Type | Agent Flag | Overhead |
|---|---|---|
| CPU (`cpu`) | default sampling | 1-3% |
| Allocation (`alloc`) | `-Dpyroscope.profiler.alloc=512k` | 2-5% |
| Lock (`lock`) | `-Dpyroscope.profiler.lock=10ms` | 1-3% |
| Wall clock (`wall`) | default sampling | 1-2% |
| All combined (current config) | all of the above | 3-8% |

### Tuning if overhead is too high

If a service shows >10% overhead:

- **Raise the allocation threshold**: change `-Dpyroscope.profiler.alloc=512k` to `1m` or `2m` in `docker-compose.yaml`. Higher threshold = fewer allocation samples = less overhead.
- **Raise the lock threshold**: change `-Dpyroscope.profiler.lock=10ms` to `50ms`. Captures fewer lock events.
- **Disable a profile type**: remove `-Dpyroscope.profiler.lock=10ms` or `-Dpyroscope.profiler.alloc=512k` to disable lock or alloc profiling respectively.
- **Re-run the benchmark** after each change to confirm the reduction.

### Production validation checklist

Before enabling profiling on a production workload:

1. Run `bash scripts/run.sh benchmark 500 100` on identical hardware.
2. Confirm all services show <10% latency overhead.
3. Check p99 specifically — profiling should not introduce tail latency spikes.
4. Monitor JVM heap usage (`jvm_memory_used_bytes` in Prometheus) with and without the agent — the agent itself adds ~20-40 MB heap.
5. Run under sustained load (not just short bursts) to catch GC pressure from the agent's profile buffers.

---

## Maintenance

### Updating Images

```bash
docker compose pull pyroscope
docker compose build --no-cache
docker compose up -d
```

### Data Retention

Pyroscope and Prometheus store data in Docker volumes.

```bash
docker system df -v | grep -E "pyroscope|prometheus|grafana"
```

Pyroscope retention: `config/pyroscope/pyroscope.yaml`. Prometheus default: 15 days.

To reset all data:

```bash
docker compose down -v
docker compose up -d
```

### Backup

```bash
for uid in pyroscope-java-overview jvm-metrics-deep-dive http-performance service-comparison; do
  curl -sf -u admin:admin "http://localhost:3000/api/dashboards/uid/$uid" | python3 -m json.tool > "backup-$uid.json"
done
```

---

## Configuration Reference

### Services

| Service | Image | Internal Port | Config |
|---------|-------|---------------|--------|
| Pyroscope | grafana/pyroscope:latest | 4040 | `config/pyroscope/pyroscope.yaml` |
| Prometheus | prom/prometheus:v2.53.0 | 9090 | `config/prometheus/prometheus.yaml` |
| Grafana | grafana/grafana:11.5.2 | 3000 | `config/grafana/provisioning/` |
| API Gateway | built from `sample-app/` | 8080 | `JAVA_TOOL_OPTIONS` env var |
| Order Service | built from `sample-app/` | 8081 | Batch processing + synchronized blocks |
| Payment Service | built from `sample-app/` | 8082 | Payment processing simulation |
| Fraud Service | built from `sample-app/` | 8083 | Fraud detection algorithms |
| Account Service | built from `sample-app/` | 8084 | Account lookups and balance management |
| Loan Service | built from `sample-app/` | 8085 | Loan calculation and amortization |
| Notification Service | built from `sample-app/` | 8086 | Notification dispatch and templating |

Host-side ports are configured in `.env` and may differ from internal ports. The run script banner shows the actual URLs.

### Dashboards

| Dashboard | UID | Purpose |
|-----------|-----|---------|
| Pyroscope Overview | `pyroscope-java-overview` | Flame graphs + JVM metrics |
| JVM Metrics Deep Dive | `jvm-metrics-deep-dive` | CPU, memory, GC, threads |
| HTTP Performance | `http-performance` | Request rate, latency, errors |
| Service Comparison | `service-comparison` | Side-by-side service comparison |
| Before vs After Fix | `before-after-comparison` | Compare flame graphs before/after `OPTIMIZED=true` |

### Alert Rules

| Alert | Condition | Severity |
|-------|-----------|----------|
| `HighCpuUsage` | CPU > 80% for 1m | warning |
| `HighHeapUsage` | Heap > 85% for 2m | warning |
| `HighGcPauseRate` | GC > 50ms/s for 1m | warning |
| `HighErrorRate` | 5xx > 5% for 1m | critical |
| `HighLatency` | p99 > 2s for 2m | warning |
| `ServiceDown` | Scrape fails for 30s | critical |

### Pyroscope Agent Flags

| Flag | Value | Purpose |
|------|-------|---------|
| `pyroscope.application.name` | e.g. `bank-api-gateway` | Groups profiles in UI |
| `pyroscope.server.address` | `http://pyroscope:4040` | Profile destination |
| `pyroscope.format` | `jfr` | Java Flight Recorder format |
| `pyroscope.profiler.event` | `cpu,alloc,lock` | Profile types to collect |
| `pyroscope.profiler.alloc` | `512k` | Allocation sampling threshold |
| `pyroscope.labels.*` | key=value | Static labels for filtering |
| `pyroscope.upload.interval` | `10s` (default) | Upload frequency |

---

## Known Hotspots by Service

Expected flame graph patterns. Anything not listed here may be a regression.

### bank-api-gateway (MainVerticle)

| Profile | Expected hot methods | Why |
|---------|---------------------|-----|
| CPU | `fibonacci(int)` | Recursive O(2^n) computation for `/cpu` endpoint |
| CPU | `simulateDatabaseWork()` | Sorts 50K strings for `/db/*` endpoints |
| Memory | `simulateDatabaseWork()` | Allocates ArrayList of 50K String objects |
| Memory | `BatchHandler`, `SerializationHandler` | Per-request buffer allocation |

### bank-order-service (OrderVerticle)

| Profile | Expected hot methods | Why |
|---------|---------------------|-----|
| CPU | `validateOrder()` | Regex pattern matching on order fields |
| CPU | `aggregateOrders()` | HashMap group-by computation |
| Memory | `buildOrder()` | LinkedHashMap + ArrayList + String concatenation per order |
| **Mutex** | **`processOrders()`** | **Synchronized method — intentional lock contention** |

### bank-payment-service (PaymentVerticle)

| Profile | Expected hot methods | Why |
|---------|---------------------|-----|
| CPU | `sha256()` | SHA-256 hashing via `MessageDigest.digest()` |
| CPU | `handleFxConversion()` | 20 iterations of BigDecimal.multiply with DECIMAL128 |
| Memory | `handlePayroll()` | BigDecimal objects in 200-500 iteration loop |
| **Mutex** | **`handlePayroll()`** | **Synchronized batch — threads serialize** |

### bank-fraud-service (FraudDetectionVerticle)

| Profile | Expected hot methods | Why |
|---------|---------------------|-----|
| **CPU** | **`handleScan()`** | **Regex matching 10K events x 8 patterns** |
| CPU | `handleScore()` | Pattern.matcher().find() + Math.log1p/Gaussian |
| CPU | `handleAnomaly()` | Mean/stddev/percentile + Collections.sort |
| Memory | `handleIngest()` | Creates 50-150 HashMap objects per call |

### bank-account-service (AccountVerticle)

| Profile | Expected hot methods | Why |
|---------|---------------------|-----|
| CPU | `handleInterest()` | 30-day compound interest loop with BigDecimal |
| CPU | `handleSearch()` | Stream filter/sort/collect over all accounts |
| Memory | `handleStatement()` | StringBuilder + multiple String.format() calls |
| Memory | `handleBranchSummary()` | LinkedHashMap + BigDecimal merge over all accounts |
| **Mutex** | **`handleDeposit()` / `handleWithdraw()`** | **Synchronized balance updates** |

### bank-loan-service (LoanVerticle)

| Profile | Expected hot methods | Why |
|---------|---------------------|-----|
| **CPU** | **`handleRiskSim()`** | **10,000 Monte Carlo iterations with Math.random** |
| CPU | `handleAmortize()` / `power()` | BigDecimal exponentiation loop (up to 360 iterations) |
| CPU | `handleApply()` | Weighted scoring with floating-point math |
| Memory | `handlePortfolio()` | Two LinkedHashMaps + BigDecimal merge over 3K loans |

### bank-notification-service (NotificationVerticle)

| Profile | Expected hot methods | Why |
|---------|---------------------|-----|
| **Memory** | **`renderTemplate()`** | **String.format() creates new String per call** |
| **Memory** | **`handleBulk()`** | **500-2000 LinkedHashMap allocations in loop** |
| CPU | `handleRender()` | 200-500 String.format() calls |
| CPU | `handleRetry()` | Exponential backoff with bit-shift loop |

---

## Remediation Patterns

### CPU

| Flame graph finding | Fix |
|--------------------|-----|
| Recursive method (`fibonacci`) | Iterative + memoization |
| `Pattern.compile()` inside method | Extract to `static final Pattern` |
| `BigDecimal` in loop | Cache intermediates; consider `double` if precision allows |
| `Collections.sort()` on large list | Bounded priority queue or pre-sorted structure |
| `String.format()` in loop | `StringBuilder` + manual append |
| `MessageDigest.digest()` repeated | Batch signing; async worker thread |
| `Math.random()` in tight loop | `ThreadLocalRandom.current()` |

### Memory

| Flame graph finding | Fix |
|--------------------|-----|
| `ArrayList.grow()` / `ArrayList.<init>` | `new ArrayList<>(expectedSize)` |
| `HashMap.resize()` | `new HashMap<>(expectedSize, 0.75f)` |
| `String +=` in loop | `StringBuilder` |
| `String.format()` in loop | Pre-build with `StringBuilder` |
| `new LinkedHashMap()` per request | Object pool or builder pattern |
| `byte[]` per request | `ByteBuffer` pool or Netty `ByteBuf` |
| `BigDecimal` intermediates | Minimize steps; reuse `MathContext` |

### Lock Contention

| Flame graph finding | Fix |
|--------------------|-----|
| `synchronized` method on hot path | Narrow to critical section only |
| `synchronized` on shared state | `ConcurrentHashMap` or `AtomicReference` |
| Multiple threads writing same map | `ConcurrentHashMap.compute()` |
| Lock held during I/O | Move I/O outside synchronized block |
| Thread pool exhaustion | `vertx.executeBlocking()` for blocking calls |
| `ReentrantLock` with long hold | Split into fine-grained locks |

### Latency

| Root cause | Fix |
|-----------|-----|
| CPU-bound handler on event loop | `vertx.executeBlocking()` |
| Downstream service timeout | Circuit breaker (`resilience4j`) |
| GC pause during request | Reduce allocation rate |
| Lock contention serializing requests | Reduce lock scope |
| `Thread.sleep` in handler | `vertx.setTimer()` |

---

## Troubleshooting

### Profiles not appearing in Pyroscope

```bash
# Verify agent loaded
docker compose logs bank-api-gateway 2>&1 | grep -i "pyroscope\|async-profiler"

# Check Pyroscope is receiving data
curl -s 'http://localhost:4040/pyroscope/label-values?label=service_name'

# Check connectivity from app container
docker compose exec bank-api-gateway curl -sf http://pyroscope:4040/ready

# Check JAVA_TOOL_OPTIONS
docker compose exec bank-api-gateway env | grep JAVA_TOOL_OPTIONS
```

### Explore Profiles shows "plugin not installed"

```bash
bash scripts/run.sh teardown
bash scripts/run.sh
```

Verify plugin is active:

```bash
curl -sf -u admin:admin 'http://localhost:3000/api/plugins/grafana-pyroscope-app/settings' | python3 -m json.tool
```

### Grafana shows "No data"

1. Check time range — must include a period when load was running.
2. Check datasource:
   ```bash
   curl -sf -u admin:admin 'http://localhost:3000/api/datasources/proxy/uid/pyroscope-ds/ready'
   ```
3. Restart Grafana:
   ```bash
   docker compose restart grafana
   ```

### Build failures

```bash
docker builder prune -f
docker compose build --no-cache
docker system info | grep -E "Memory|CPUs"
```

Minimum 8 GB RAM to build and run all services.

### Port conflicts

```bash
ss -tlnp | grep -E '3000|4040|8080|8081|8082|8083|8084|8085|8086|9090'
```

Change port mappings in `docker-compose.yaml` or let the deploy script auto-assign via `.env`.

### Container keeps restarting

```bash
docker compose ps -a
docker inspect <container> | grep -i oom
```

If OOM-killed, add a memory limit in `docker-compose.yaml`:

```yaml
deploy:
  resources:
    limits:
      memory: 512M
```
