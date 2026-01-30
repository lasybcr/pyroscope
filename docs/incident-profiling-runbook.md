# Incident Profiling Runbook — Java Services

Step-by-step procedures for using Pyroscope continuous profiling to identify
the exact classes and methods causing CPU, memory, thread, and latency issues
during production incidents. Every step includes both CLI and UI paths.

---

## Table of Contents

1. [First 60 Seconds — Triage](#first-60-seconds--triage)
2. [High CPU — Find the Hot Method](#high-cpu--find-the-hot-method)
3. [Memory Leak / High Heap — Find the Allocator](#memory-leak--high-heap--find-the-allocator)
4. [GC Pressure — Find What's Creating Garbage](#gc-pressure--find-whats-creating-garbage)
5. [Lock Contention / Thread Starvation](#lock-contention--thread-starvation)
6. [Latency Spike — Narrow the Bottleneck](#latency-spike--narrow-the-bottleneck)
7. [Post-Deploy Regression — Diff the Profiles](#post-deploy-regression--diff-the-profiles)
8. [Reading a Flame Graph](#reading-a-flame-graph)
9. [Known Hotspots by Service](#known-hotspots-by-service)
10. [Remediation Patterns](#remediation-patterns)
11. [Escalation Checklist](#escalation-checklist)
12. [API Quick Reference](#api-quick-reference)

---

## First 60 Seconds — Triage

Run this immediately when paged. It tells you which services are unhealthy,
what the HTTP traffic looks like, which functions are hottest, and whether
any alerts are firing — all in one command.

```bash
bash scripts/run.sh diagnose
```

Or for one specific service:

```bash
bash scripts/diagnose.sh --service bank-payment-service
```

JSON output for scripting or sharing in Slack:

```bash
bash scripts/run.sh diagnose --json | jq .
```

**What to look at first:**

| Section | What it tells you | Next step |
|---------|-------------------|-----------|
| `JVM HEALTH` | Which services have high CPU, heap, GC, threads | Go to that service's section below |
| `HTTP TRAFFIC` | Request rate, error rate, avg latency per service | High errors → check logs. High latency → check profiles |
| `PROFILING HOTSPOTS` | Top function consuming CPU/memory/mutex per service | You now know the class and method — go to code |
| `FIRING ALERTS` | Which Prometheus alerts are active | Confirms the symptom |

---

## High CPU — Find the Hot Method

**Symptom:** `HighCpuUsage` alert fires, or `diagnose` shows CPU > 50%.

### Step 1: Identify the top CPU functions

```bash
# All services
bash scripts/run.sh top cpu

# One service
bash scripts/top-functions.sh cpu bank-api-gateway
```

Example output:

```
--- bank-api-gateway ---
    1.  42.3%         1.85s  com.example.MainVerticle.fibonacci
    2.  12.1%         0.53s  com.example.MainVerticle.lambda$start$3
    3.   8.7%         0.38s  java.math.BigDecimal.multiply
```

**You now know:** `MainVerticle.fibonacci` is consuming 42.3% of CPU self-time.

### Step 2: Confirm with the flame graph (UI)

1. Open Pyroscope: http://localhost:4040
2. Select application: `bank-api-gateway`
3. Profile type: `process_cpu:cpu:nanoseconds:cpu:nanoseconds`
4. Time range: narrow to the incident window
5. Look for the widest bar — that's the method burning CPU

Or in Grafana: http://localhost:3000/d/pyroscope-java-overview
- Select the service from the `application` dropdown
- The CPU flame graph panel shows the same data

### Step 3: Determine if it's application code or JVM internals

| What you see at the top of the flame graph | Meaning | Action |
|-------------------------------------------|---------|--------|
| `com.example.*` methods | Your application code is CPU-bound | Optimize the hot method |
| `java.util.regex.Pattern` | Regex engine in a loop | Pre-compile patterns, reduce backtracking |
| `java.math.BigDecimal.*` | Financial calculations | Expected for payment/loan — consider caching results |
| `java.security.MessageDigest` | Cryptographic hashing | Expected for payment signing — consider async offload |
| `jdk.internal.gc.*` / `G1*` | Garbage collector | Not a CPU issue — switch to Memory profile |
| `java.util.Arrays.sort` / `TimSort` | Sorting large collections | Pre-sort or limit collection size |
| `io.vertx.core.*` | Vert.x event loop overhead | Blocking the event loop — use `executeBlocking()` |

### Step 4: Validate the fix

After making a change:

```bash
# Re-check CPU functions
bash scripts/top-functions.sh cpu bank-api-gateway

# Compare before/after
bash scripts/diagnose.sh --service bank-api-gateway --json > after.json
```

---

## Memory Leak / High Heap — Find the Allocator

**Symptom:** `HighHeapUsage` alert fires (heap > 85%), or steady heap growth
in the JVM Metrics dashboard.

### Step 1: Check heap status

```bash
bash scripts/run.sh health
```

Look for services with `Heap warning` or `Heap critical`.

### Step 2: Identify what's allocating the most memory

```bash
# All services
bash scripts/run.sh top memory

# One service
bash scripts/top-functions.sh memory bank-notification-service
```

Example output:

```
--- bank-notification-service ---
    1.  28.4%      12.3 MB  com.example.NotificationVerticle.renderTemplate
    2.  15.2%       6.6 MB  com.example.NotificationVerticle.handleBulk
    3.  11.8%       5.1 MB  java.lang.String.format
```

**You now know:** `renderTemplate` is the top memory allocator.

### Step 3: Understand what the allocation profile shows

The memory flame graph shows **where objects are allocated**, not where they're
retained. But high allocators are the first suspects for both GC pressure and leaks.

| What you see | Meaning |
|-------------|---------|
| `String.format` / `StringBuilder.toString` | Heavy string construction — template rendering, logging |
| `ArrayList.<init>` / `ArrayList.grow` | Collection resizing — pre-size with expected capacity |
| `HashMap.put` / `HashMap.resize` | Map resizing — pre-size or use fixed-capacity structures |
| `BigDecimal.*` | Financial arithmetic creates many intermediate objects |
| `byte[]` / `char[]` | Raw buffer allocations — object pooling candidate |
| `LinkedHashMap.<init>` | Per-request map creation — consider reusable builders |

### Step 4: Check if it's a leak (UI)

Open Grafana → JVM Metrics Deep Dive → Heap Memory panel:
- **Sawtooth pattern** (rises then drops) = normal GC, not a leak
- **Steadily rising line** that never drops = probable leak
- **Flat at max** = OOM imminent — restart the service immediately

```bash
# Quick check via CLI
curl -s 'http://localhost:9090/api/v1/query?query=jvm_memory_used_bytes{job="jvm",area="heap"}' | \
  python3 -c "
import json, sys
for r in json.load(sys.stdin)['data']['result']:
    inst = r['metric']['instance'].split(':')[0]
    mb = float(r['value'][1]) / 1024 / 1024
    print(f'  {inst}: {mb:.0f} MB')"
```

---

## GC Pressure — Find What's Creating Garbage

**Symptom:** `HighGcPauseRate` alert fires (GC > 50ms/s), or frequent GC
pauses visible in JVM Metrics dashboard.

### Step 1: Confirm GC is the problem

```bash
bash scripts/run.sh health
```

Look for `GC warning` or `GC critical`. Then check which GC type:

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

- **Young/Minor GC** high = lots of short-lived objects being created
- **Old/Major GC** high = long-lived objects filling old gen — likely a leak

### Step 2: Find the allocation hotspot

```bash
bash scripts/top-functions.sh memory bank-payment-service
```

The top allocating methods are creating the garbage. Reduce their allocation
rate to reduce GC pressure.

### Step 3: Cross-reference with CPU profile

Often GC pressure shows up in the CPU profile too:

```bash
bash scripts/top-functions.sh cpu bank-payment-service
```

If you see `jdk.internal.gc.*` or `G1*` methods consuming significant CPU,
that confirms GC is eating your CPU budget.

---

## Lock Contention / Thread Starvation

**Symptom:** High latency despite low CPU. Threads piling up. Requests timing
out. The CPU flame graph looks normal but the service is slow.

### Step 1: Check thread counts

```bash
curl -s 'http://localhost:9090/api/v1/query?query=jvm_threads_current{job="jvm"}' | \
  python3 -c "
import json, sys
for r in json.load(sys.stdin)['data']['result']:
    inst = r['metric']['instance'].split(':')[0]
    val = int(float(r['value'][1]))
    flag = ' ⚠️' if val > 50 else ''
    print(f'  {inst}: {val} threads{flag}')"
```

### Step 2: Find contended locks

```bash
# All services
bash scripts/run.sh top mutex

# One service
bash scripts/top-functions.sh mutex bank-order-service
```

Example output:

```
--- bank-order-service ---
    1.  67.2%      1,842 events  com.example.OrderVerticle.processOrders
    2.  18.5%        508 events  com.example.OrderVerticle.aggregateOrders
```

**You now know:** `processOrders` has a `synchronized` block causing 67% of
all lock contention.

### Step 3: Understand what the mutex profile shows

| What you see | Meaning |
|-------------|---------|
| `*.processOrders` / `*.handlePayroll` | Application-level synchronized method — all threads serialize here |
| `*.handleDeposit` / `*.handleWithdraw` | Account balance updates hold locks — concurrent deposits block each other |
| `java.util.concurrent.locks.*` | Explicit lock contention — check lock scope |
| `io.vertx.core.impl.*` | Vert.x internal lock — event loop may be blocked |

### Step 4: Verify lock impact on latency

```bash
bash scripts/diagnose.sh --section http --service bank-order-service
```

If avg latency is high but CPU is low, lock contention is confirmed as the
bottleneck.

---

## Latency Spike — Narrow the Bottleneck

**Symptom:** `HighLatency` alert fires (p99 > 2s), or users report slow responses.

### Step 1: Find the slow service and endpoint

```bash
bash scripts/diagnose.sh --section http
```

Look at the `Slowest endpoints` list and per-service `Avg Lat` column.

### Step 2: Determine the bottleneck type

For the affected service, check all three profile types:

```bash
SERVICE=bank-payment-service

# Is it CPU-bound?
bash scripts/top-functions.sh cpu $SERVICE

# Is it allocation-bound (GC pauses)?
bash scripts/top-functions.sh memory $SERVICE

# Is it lock-bound?
bash scripts/top-functions.sh mutex $SERVICE
```

| CPU profile shows hot methods | Memory profile shows high allocation | Mutex profile shows contention | Diagnosis |
|-----|-----|-----|-----|
| Yes | No | No | CPU-bound — optimize the hot function |
| No | Yes | No | GC-bound — reduce allocation rate |
| No | No | Yes | Lock-bound — reduce synchronized scope |
| No | No | No | Off-CPU — blocking I/O, downstream call, or Thread.sleep |
| Yes | Yes | No | CPU + allocation — heavy computation creating temp objects |
| Yes | No | Yes | CPU + lock — threads spinning while waiting for locks |

### Step 3: If off-CPU (nothing shows in any profile)

The method is blocked waiting for something external:

```bash
# Check container logs for timeouts or connection errors
docker logs payment-service --tail 100 2>&1 | grep -iE "timeout|connect|refused|error"

# Check if downstream services are healthy
bash scripts/run.sh health
```

---

## Post-Deploy Regression — Diff the Profiles

**Symptom:** Performance alerts fire shortly after a deployment.

### Step 1: Capture current state

```bash
bash scripts/diagnose.sh --json > post-deploy.json
```

### Step 2: Compare CPU hotspots

If you have a pre-deploy baseline:

```bash
# Before deploy (saved earlier)
jq '.profiles[] | select(.service=="bank-payment-service") | .cpu_top5' pre-deploy.json

# After deploy
jq '.profiles[] | select(.service=="bank-payment-service") | .cpu_top5' post-deploy.json
```

### Step 3: Use Pyroscope comparison view (UI)

1. Open Pyroscope: http://localhost:4040
2. Click **Comparison** view
3. Left: time range before the deploy
4. Right: time range after the deploy
5. **Red** bars = methods consuming more resources after deploy
6. **Green** bars = methods consuming fewer resources

### Step 4: Use Grafana diff (UI)

1. Open Grafana → Pyroscope Overview
2. Set time range to span the deploy boundary
3. Compare the flame graph shape before and after

---

## Reading a Flame Graph

### Orientation

```
      ┌──────────────────────────────────────────┐
      │              main() thread               │  ← bottom: entry point
      ├─────────────────────┬────────────────────┤
      │   handleRequest()   │   eventLoop()      │  ← callers
      ├──────────┬──────────┤                    │
      │ compute()│ sha256() │                    │  ← top: leaf functions
      └──────────┴──────────┴────────────────────┘
                     WIDTH = TIME SPENT
```

- **X-axis (width):** proportional to time (CPU), bytes (memory), or events (mutex)
- **Y-axis (height):** call stack depth — callers at bottom, callees at top
- **Color:** arbitrary — groups related stacks but has no metric meaning
- **Self-time:** time spent in the function itself, not its children

### What to look for

| Pattern | Meaning |
|---------|---------|
| **Wide bar at the top** | This leaf function is the actual hotspot — it consumes time directly |
| **Wide bar in the middle, narrow children** | This function is hot because it calls many small functions |
| **Very deep stack** | Deep recursion or complex call chain — look for recursive patterns |
| **Single wide tower** | One code path dominates — likely a single endpoint under heavy load |
| **Flat plateau** | Many different functions each consuming a small slice — no single hotspot |

### Self-time vs total-time

- **Self-time:** time the function itself spent on the CPU (not its children)
- **Total-time:** self-time + time of all child calls

The `top-functions.sh` script reports **self-time**, which is what you want for
finding the actual bottleneck rather than a high-level caller.

### Clicking in the UI

- **Click a bar** → zooms into that subtree
- **Right-click → Focus** → isolates that function and its callers
- **Sandwich view** → shows a function's callers (above) and callees (below) together

---

## Known Hotspots by Service

Expected flame graph patterns for each service. If you see something not on
this list, it may be a regression.

### bank-api-gateway (MainVerticle)

| Profile | Expected hot methods | Why |
|---------|---------------------|-----|
| CPU | `fibonacci(int)` | Recursive O(2^n) computation for `/cpu` endpoint |
| CPU | `simulateDatabaseWork()` | Sorts 50K strings for `/db/*` endpoints |
| Memory | `simulateDatabaseWork()` | Allocates ArrayList of 50K String objects |
| Memory | Handlers: `BatchHandler`, `SerializationHandler` | Per-request buffer allocation |

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
| **Mutex** | **`handlePayroll()`** | **Synchronized batch — threads serialize here** |

### bank-fraud-service (FraudDetectionVerticle)

| Profile | Expected hot methods | Why |
|---------|---------------------|-----|
| **CPU** | **`handleScan()`** | **Regex matching 10K events × 8 patterns** |
| CPU | `handleScore()` | Pattern.matcher().find() + Math.log1p/Gaussian |
| CPU | `handleAnomaly()` | Mean/stddev/percentile calculation + Collections.sort |
| Memory | `handleIngest()` | Creates 50-150 HashMap objects per call |

### bank-account-service (AccountVerticle)

| Profile | Expected hot methods | Why |
|---------|---------------------|-----|
| CPU | `handleInterest()` | 30-day compound interest loop with BigDecimal math |
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

Common fixes mapped to what you see in the flame graph.

### CPU Remediation

| Flame graph finding | Fix |
|--------------------|----|
| Recursive method (`fibonacci`) | Replace with iterative + memoization |
| `Pattern.compile()` inside a method | Extract to `static final Pattern` field |
| `BigDecimal` arithmetic in a loop | Cache intermediate results; consider `double` if precision allows |
| `Collections.sort()` on large list | Use bounded priority queue (`TreeMap` with max size) or pre-sorted structure |
| `String.format()` in a loop | Use `StringBuilder` and manual append |
| `MessageDigest.digest()` repeated | Batch signing; use async worker thread |
| `Math.random()` in tight loop | Use `ThreadLocalRandom.current()` |

### Memory Remediation

| Flame graph finding | Fix |
|--------------------|----|
| `ArrayList.grow()` / `ArrayList.<init>` | Pre-size: `new ArrayList<>(expectedSize)` |
| `HashMap.resize()` | Pre-size: `new HashMap<>(expectedSize, 0.75f)` |
| `String +=` in loop | Use `StringBuilder` |
| `String.format()` in loop | Pre-build template with `StringBuilder` |
| `new LinkedHashMap()` per request | Reuse via object pool or builder pattern |
| `byte[]` allocation per request | Use `ByteBuffer` pool or Netty `ByteBuf` |
| `BigDecimal` intermediate objects | Minimize intermediate steps; reuse `MathContext` |

### Lock Contention Remediation

| Flame graph finding | Fix |
|--------------------|----|
| `synchronized` method on hot path | Narrow to `synchronized(this) { ... }` on just the critical section |
| `synchronized` on shared state | Replace with `ConcurrentHashMap` or `AtomicReference` |
| Multiple threads writing same map | Use `ConcurrentHashMap.compute()` instead of `get` + `put` |
| Lock held during I/O or computation | Move I/O outside the synchronized block |
| Thread pool exhaustion | Use Vert.x `executeBlocking()` for blocking calls |
| `ReentrantLock` with long hold time | Split into multiple fine-grained locks |

### Latency Remediation

| Root cause | Fix |
|-----------|-----|
| CPU-bound handler on event loop | Move to `vertx.executeBlocking()` |
| Downstream service timeout | Add circuit breaker (`resilience4j`) |
| GC pause during request | Reduce allocation rate (see Memory above) |
| Lock contention serializing requests | Reduce lock scope (see Lock above) |
| Thread.sleep in handler | Replace with `vertx.setTimer()` |

---

## Escalation Checklist

Use this when the incident requires escalation to another team.

### Information to include

```bash
# Generate and attach this to the incident ticket
bash scripts/diagnose.sh --json > incident-$(date +%Y%m%d-%H%M%S).json
```

The JSON file contains everything needed for a handoff:
- JVM health metrics for all services
- HTTP traffic stats (request rate, error rate, latency)
- Top 5 CPU/memory/mutex functions per service
- Firing alerts

### Escalation template

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

## API Quick Reference

### Pyroscope — Get profile data

```bash
# List all profiled applications
curl -s 'http://localhost:4040/querier.v1.QuerierService/LabelValues' \
  -X POST -H 'Content-Type: application/json' \
  -d '{"name":"service_name"}'

# CPU profile as JSON
curl -s "http://localhost:4040/pyroscope/render?\
query=process_cpu:cpu:nanoseconds:cpu:nanoseconds\
%7Bservice_name%3D%22bank-api-gateway%22%7D\
&from=now-1h&until=now&format=json"

# Memory profile
curl -s "http://localhost:4040/pyroscope/render?\
query=memory:alloc_in_new_tlab_bytes:bytes:space:bytes\
%7Bservice_name%3D%22bank-api-gateway%22%7D\
&from=now-1h&until=now&format=json"

# Mutex profile
curl -s "http://localhost:4040/pyroscope/render?\
query=mutex:contentions:count:mutex:count\
%7Bservice_name%3D%22bank-order-service%22%7D\
&from=now-1h&until=now&format=json"
```

### Prometheus — Get JVM metrics

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

### CLI tools

```bash
bash scripts/run.sh diagnose                        # full report
bash scripts/run.sh diagnose --json                  # JSON for scripting
bash scripts/diagnose.sh --service bank-api-gateway  # one service
bash scripts/diagnose.sh --section health            # health only
bash scripts/run.sh health                           # JVM health check
bash scripts/run.sh health --json                    # health as JSON
bash scripts/run.sh top cpu                          # CPU hotspots
bash scripts/run.sh top memory                       # allocation hotspots
bash scripts/run.sh top mutex                        # lock contention
bash scripts/top-functions.sh cpu bank-api-gateway   # one service, one profile
bash scripts/top-functions.sh --top 20 --range 30m   # custom params
```
