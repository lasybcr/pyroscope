# Profiling Scenarios — Finding Issues with Pyroscope in Grafana

Step-by-step walkthroughs using Pyroscope flame graphs in Grafana to identify real performance issues. Each scenario follows the same pattern: notice a symptom in metrics, switch to the flame graph to find the root cause.

Prerequisites: stack running with load (`bash scripts/run.sh`).

---

## Scenario 1: CPU Hotspot — Recursive Algorithm

**Symptom:** API Gateway has high CPU usage relative to other services.

**Steps in Grafana:**

1. Open **Service Performance** dashboard
2. Look at **Request Rate by Service** — all services get similar traffic
3. Look at **Avg Latency by Service** — `api-gateway` latency is noticeably higher on `/cpu` endpoint
4. This tells you *what* is slow but not *why*

**Switch to the flame graph:**

5. On the same dashboard, scroll to the **Flame Graph** panel (or open **Pyroscope Java Overview**)
6. Set the `pyroscope_app` dropdown to `bank-api-gateway`
7. Set `profile_type` to `cpu`
8. The flame graph renders — look for the **widest bar** near the top of the graph

**What you see:**

```
MainVerticle.handleCpu()
  └── MainVerticle.fibonacci()
        ├── MainVerticle.fibonacci()     ← recursive call (wide)
        │     └── MainVerticle.fibonacci()
        └── MainVerticle.fibonacci()     ← recursive call (wide)
```

The `fibonacci()` frame is extremely wide — it dominates CPU time. The recursion is visible as nested calls of the same function. This is O(2^n) complexity.

**Root cause:** Recursive Fibonacci implementation. Each call spawns two more calls.

**Verify the fix:** Deploy with `OPTIMIZED=true` (uses iterative version), then compare the flame graph — the `fibonacci` frame shrinks dramatically. Use the **Before vs After Fix** dashboard to see both side by side.

---

## Scenario 2: Hidden Per-Request Overhead — Crypto Provider Lookup

**Symptom:** Payment service has higher CPU than expected for its traffic volume.

**Steps in Grafana:**

1. Open **Pyroscope Java Overview** (or the flame graph panel on any dashboard)
2. Set `application` to `bank-payment-service`
3. Set `profile_type` to `cpu`

**What you see:**

```
PaymentVerticle.handleTransfer()
  └── PaymentVerticle.sha256()
        ├── MessageDigest.getInstance("SHA-256")   ← 18% self-time
        ├── MessageDigest.digest()                  ← 12% self-time (expected)
        └── String.format("%02x", b)               ← 4% self-time
```

**How to read this:** `MessageDigest.getInstance()` is wide — it's looking up the JCE security provider registry on **every single request**. This is a static lookup that should happen once. `String.format` is boxing each byte into an Integer for hex formatting — unnecessary allocation and CPU work.

**Root cause:** Per-request provider lookup + autoboxing in a tight loop. Neither would be obvious from code review alone.

**Key insight:** The flame graph exposes overhead hidden inside JDK library calls. You didn't write `MessageDigest.getInstance()` but you're paying for it on every request.

---

## Scenario 3: Memory Allocation Pressure — String.format

**Symptom:** Notification service has frequent GC pauses visible in the JVM Metrics dashboard (high GC collection duration rate).

**Steps in Grafana:**

1. Open **JVM Metrics Deep Dive** — confirm high GC rate for `notification-service`
2. The heap panel shows a rapid sawtooth: memory fills quickly, GC runs frequently
3. This tells you something is allocating fast — but what?

**Switch to allocation flame graph:**

4. Open **Pyroscope Java Overview**
5. Set `application` to `bank-notification-service`
6. Set `profile_type` to `alloc (memory)`

**What you see:**

```
NotificationVerticle.handleRender()
  └── NotificationVerticle.renderTemplate()
        └── String.format()
              ├── Formatter.format()          ← wide bar
              │     └── Formatter.parse()
              └── new Object[]{}              ← varargs array allocation
```

The `String.format()` and `Formatter` frames dominate the allocation profile. Every template render creates multiple intermediate String objects, a Formatter instance, and a varargs Object array.

**Root cause:** `String.format()` in a hot loop. Each call allocates temporary objects that become garbage immediately.

**Fix pattern:** Replace with `StringBuilder` + manual substitution. The optimized version (`OPTIMIZED=true`) does this — the allocation flame graph becomes flat with StringBuilder's single buffer resize.

**How to correlate:** Open two browser tabs — JVM Metrics (GC rate) and Pyroscope Overview (alloc profile). The GC rate tells you *how bad* the problem is. The allocation flame graph tells you *which function* to fix.

---

## Scenario 4: Lock Contention — Synchronized Methods

**Symptom:** Order service latency increases under load, but CPU stays low.

This is the tricky one — low CPU + high latency usually means threads are **waiting**, not working.

**Steps in Grafana:**

1. Open **HTTP Performance** — confirm order-service latency is high
2. Open **JVM Metrics Deep Dive** — CPU is low (~15%), threads may be elevated
3. Low CPU + high latency = threads are blocked on something

**Switch to mutex flame graph:**

4. Open **Pyroscope Java Overview**
5. Set `application` to `bank-order-service`
6. Set `profile_type` to `mutex (lock)`

**What you see:**

```
OrderVerticle.handleProcess()
  └── OrderVerticle.processOrdersSynchronized()     ← wide bar
        └── java.lang.Object.wait()                  ← threads waiting for the lock
```

The `processOrdersSynchronized` frame is wide in the mutex profile — this is a `synchronized` method that forces all concurrent requests through a single lock. Under load, threads queue up waiting for the lock.

**Root cause:** `synchronized` method serializes all order processing. Only one thread can execute at a time.

**Fix pattern:** Replace with `ConcurrentHashMap.computeIfPresent()` for lock-free updates. After the fix, the mutex flame graph becomes flat — no contention.

**Key insight:** This issue is invisible in CPU profiles. CPU is low because threads are sleeping, not computing. Only the **mutex profile type** reveals it.

---

## Scenario 5: Before vs After Comparison

**Use case:** You've deployed a fix and want to prove it worked with data, not guesses.

**Steps in Grafana:**

1. Run `bash scripts/run.sh compare` in the terminal — this generates load before and after applying optimizations
2. Open the **Before vs After Fix** dashboard in Grafana
3. Set `application` to the service you fixed (e.g., `bank-payment-service`)
4. Set `profile_type` to the relevant type (e.g., `cpu` for the sha256 fix)

**What you see:**

Two flame graph panels side by side:

- **Before Fix:** `sha256()` → `MessageDigest.getInstance()` is a wide bar (~18% of CPU)
- **After Fix:** `sha256Optimized()` → `MessageDigest.digest()` is the only visible bar, `getInstance()` is gone

The CPU metrics panels below show the aggregate impact — CPU usage for payment-service drops measurably.

**Why this matters:** Screenshots of before/after flame graphs are concrete evidence for PR reviews, incident postmortems, and stakeholder communication. It's not "we think it's faster" — it's "this function went from 18% CPU to 0%."

---

## Scenario 6: Cross-Referencing Profile Types

**Use case:** A service is slow but you're not sure if it's CPU, memory, or locks.

**Steps in Grafana:**

1. Open **Pyroscope Java Overview**
2. Select the service
3. Check each profile type in sequence using the `profile_type` dropdown:

| Profile Type | What to look for | If the flame graph is flat |
|-------------|-----------------|--------------------------|
| `cpu` | Wide bars = computation bottleneck | CPU is not the problem |
| `alloc (memory)` | Wide bars = GC pressure source | Allocations are reasonable |
| `mutex (lock)` | Wide bars = thread contention | No lock contention |

**Decision matrix:**

- **CPU hot, alloc flat, mutex flat** → pure computation problem (optimize algorithm)
- **CPU flat, alloc hot, mutex flat** → GC pressure (reduce allocations, reuse objects)
- **CPU flat, alloc flat, mutex hot** → lock contention (reduce synchronized scope)
- **CPU hot, alloc hot, mutex flat** → computation creating temp objects (common — optimize both)
- **All flat** → problem is off-CPU (network I/O, external service calls, Thread.sleep)

This is the core profiling workflow: **triangulate across profile types** to classify the bottleneck before attempting a fix.

---

## Reading Flame Graphs — Quick Reference

- **Width** of a bar = proportion of resource consumed (CPU time, allocations, or lock wait time)
- **Depth** (vertical) = call stack depth. Deeper = more nested calls
- **Top of the graph** = leaf functions doing the actual work. Start reading from the top
- **Bottom of the graph** = entry points (main, event loop, HTTP handler)
- **Color** has no meaning in Pyroscope (it's random for visual distinction)
- **Self time** = time spent in the function itself, excluding callees. A wide bar with no children = the function itself is expensive
- **Total time** = time including all callees. A wide bar with many children = the function calls expensive things

**Sandwich view** (click a function name): shows all callers above and all callees below for a single function — useful when the same function is called from multiple places.

**Diff view** (Before vs After dashboard): red = increased, green = decreased. Shows exactly which functions changed between two time ranges.

---

## Grafana Navigation Quick Reference

| To investigate... | Go to... | Set profile_type to... |
|-------------------|----------|----------------------|
| High CPU | Pyroscope Java Overview | `cpu` |
| Frequent GC / memory pressure | Pyroscope Java Overview | `alloc (memory)` |
| High latency + low CPU | Pyroscope Java Overview | `mutex (lock)` |
| Which service is worst | Service Performance | (metrics panels, then flame graph) |
| Did my fix work | Before vs After Fix | (match the profile type to your fix) |
| Side-by-side services | Service Comparison | (compares API Gateway vs Order Service) |
| JVM health overview | JVM Metrics Deep Dive | (Prometheus metrics, no profiling) |
| Endpoint-level latency | HTTP Performance | (Prometheus metrics, no profiling) |
