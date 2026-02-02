# Reducing MTTR with Continuous Profiling

How to use Pyroscope, Grafana, and the CLI tooling in this project to reduce Mean Time To Resolution (MTTR) and drive observability outcomes in production.

---

## Why Continuous Profiling Reduces MTTR

Traditional observability (metrics + logs + traces) tells you **what** is wrong — high CPU, slow responses, OOM restarts. Continuous profiling tells you **why** — the exact function, class, and line consuming the resource. This eliminates the investigation gap between "we see the symptom" and "we know the root cause."

| Without Profiling | With Profiling |
|---|---|
| Alert: CPU > 80% | Alert: CPU > 80% |
| Check metrics → confirm high CPU | `bash scripts/bottleneck.sh` → CPU-bound |
| Check logs → nothing useful | Top function: `PaymentVerticle.sha256()` at 34% self-time |
| Guess → restart → wait → still high | Open flame graph → see `MessageDigest.getInstance()` called per-request |
| Escalate to dev team → read code → reproduce | Fix: ThreadLocal MessageDigest → deploy → CPU drops to 12% |
| **Time: 45-90 minutes** | **Time: 5-15 minutes** |

The profiling data is always-on — you don't need to reproduce the issue or attach a debugger. The flame graph from the incident window is already captured.

---

## Incident Response Workflow

### 30-Second Triage

```bash
bash scripts/run.sh bottleneck
```

This single command queries Prometheus and Pyroscope, correlates JVM health with profiling hotspots, and outputs a per-service verdict:

```
  [!!!] payment-service  →  CPU-BOUND
       CPU: 82%  Heap: 45%  GC: 0.012s/s  Threads: 24  Lat: 340ms  Err: 0.0%
       Hotspot: com.example.PaymentVerticle.sha256
       Action:  Optimize com.example.PaymentVerticle.sha256 — see CPU flame graph in Pyroscope
       Profiles: CPU: PaymentVerticle.sha256 (34.2%) | Alloc: BigDecimal.<init> (12.1%) | Mutex: (none)

  [ . ] order-service  →  HEALTHY
       CPU: 15%  Heap: 38%  GC: 0.004s/s  Threads: 18  Lat: 45ms  Err: 0.0%
```

**What you now know in 30 seconds:**
- Which service is the problem
- What type of bottleneck (CPU, memory/GC, lock contention, I/O)
- The exact function causing it
- What to do next

### 2-Minute Deep Dive

Once you know the service and bottleneck type:

```bash
# Detailed function list for the affected service
bash scripts/top-functions.sh cpu bank-payment-service

# Full diagnostic with HTTP stats and alert context
bash scripts/diagnose.sh --service bank-payment-service
```

Open the Grafana flame graph to see the full call stack:
- **Pyroscope Overview** → select `bank-payment-service` → CPU profile
- Click the wide `sha256` bar → see callers and callees
- Use **Sandwich view** to see all callers of the hot function

### 5-Minute Root Cause

The flame graph shows you the exact call stack. In the `sha256` example:

```
handleTransfer()
  └── sha256()
        ├── MessageDigest.getInstance("SHA-256")  ← 18% self-time (per-call lookup)
        ├── MessageDigest.digest()                ← 12% self-time (expected)
        └── String.format("%02x", b)             ← 4% self-time (boxing + formatting)
```

**Root cause:** `getInstance()` does a provider lookup on every call. `String.format` boxes each byte. Both are avoidable.

**Fix:** ThreadLocal `MessageDigest` + `Character.forDigit()` — exactly what `OPTIMIZED=true` enables in this demo.

### Verify the Fix

```bash
# Before/after comparison on running stack
bash scripts/run.sh compare

# Or deploy with the fix and check
bash scripts/run.sh bottleneck --service bank-payment-service
```

Open the **Before vs After Fix** dashboard in Grafana to visually compare flame graphs.

---

## Bottleneck Decision Matrix

The `bottleneck` command classifies each service automatically. Here's how each verdict maps to investigation steps:

| Verdict | Symptoms | What the Flame Graph Shows | Fix Pattern |
|---------|----------|---------------------------|-------------|
| **CPU-BOUND** | High CPU rate, proportional latency increase | Wide bars at leaf functions (computation) | Algorithmic optimization, caching, async offload |
| **GC-BOUND** | Moderate CPU, high GC rate, sawtooth heap | Wide bars in allocation flame graph | Reduce allocation rate, pre-size collections, object pooling |
| **MEMORY-PRESSURE** | Heap > 75%, rising trend | Allocation flame graph shows dominant allocator | Fix leak (if rising) or increase heap (if bounded) |
| **LOCK-BOUND** | Low CPU, high latency, rising threads | Mutex flame graph shows contended `synchronized` blocks | Narrow lock scope, use concurrent data structures, lock-free algorithms |
| **I/O-BOUND** | Low CPU, high latency, nothing in profiles | Wall-clock flame graph shows `Thread.sleep` / network I/O | Connection pooling, timeouts, circuit breakers, async I/O |
| **HEALTHY** | All metrics within thresholds | Balanced, no dominant bars | No action needed |

### Cross-Referencing Profile Types

A single profile type rarely tells the full story. Cross-reference:

```bash
SERVICE=bank-order-service
bash scripts/top-functions.sh cpu $SERVICE      # what's using CPU?
bash scripts/top-functions.sh memory $SERVICE   # what's allocating?
bash scripts/top-functions.sh mutex $SERVICE    # what's contending?
```

| CPU Hot | Memory Hot | Mutex Hot | Diagnosis |
|---------|-----------|-----------|-----------|
| Yes | No | No | Pure computation — optimize the algorithm |
| No | Yes | No | GC pressure — reduce allocations |
| No | No | Yes | Lock contention — reduce synchronized scope |
| Yes | Yes | No | Computation creating temp objects — optimize both |
| No | No | No | Off-CPU — check wall-clock profile for I/O waits |
| Yes | No | Yes | Threads spinning while waiting — lock + CPU issue |

---

## Observability Outcomes

### Outcome 1: Identify the Exact Method Causing an Alert

**Scenario:** `HighCpuUsage` alert fires for `bank-api-gateway`.

```bash
bash scripts/bottleneck.sh --service bank-api-gateway
# → CPU-BOUND: MainVerticle.fibonacci at 62% self-time
```

Traditional metrics tell you CPU is high. Profiling tells you `fibonacci()` is recursive O(2^n) and should be iterative. Time from alert to root cause: under a minute.

### Outcome 2: Distinguish Real Bottlenecks from Noise

**Scenario:** Latency increased across all services after a deploy.

```bash
bash scripts/run.sh bottleneck
```

If all services show **HEALTHY** with slightly elevated latency, the issue is likely infrastructure (network, DNS, load balancer) — not application code. If one service shows **CPU-BOUND** or **LOCK-BOUND**, you know exactly where to look.

### Outcome 3: Prove a Fix Worked

**Scenario:** You optimized `processOrders()` to remove the `synchronized` block.

```bash
bash scripts/run.sh compare
```

The Before vs After dashboard shows:
- **Before:** `processOrders` dominates the mutex flame graph
- **After:** mutex flame graph is flat — contention eliminated
- **HTTP latency panel:** p99 dropped from 800ms to 120ms

This is concrete evidence for the PR review and the incident postmortem.

### Outcome 4: Capacity Planning from Profile Data

```bash
bash scripts/diagnose.sh --json | python3 -c "
import json, sys
data = json.load(sys.stdin)
for s in data.get('profiles', []):
    cpu = s.get('cpu_top5', [])
    if cpu:
        total_app = sum(f['pct'] for f in cpu if 'com.example' in f['function'])
        print(f\"{s['service']}: {total_app:.0f}% CPU in application code\")
"
```

Services where application code dominates CPU (vs JVM internals) are candidates for code optimization. Services where JVM internals dominate may need more resources or JVM tuning.

### Outcome 5: Onboarding New Team Members

New engineers can understand service behavior without reading all the code:

```bash
bash scripts/run.sh top cpu            # "what does each service spend CPU on?"
bash scripts/run.sh top memory         # "what allocates the most?"
bash scripts/run.sh top mutex          # "where are the locks?"
```

The flame graph is a map of the runtime behavior — more accurate than documentation and always up to date.

---

## Production Readiness Checklist

Before deploying profiling to production, verify:

- [ ] Profiling overhead < 10% per service (`bash scripts/run.sh benchmark`)
- [ ] `bottleneck` command works against the running stack
- [ ] Alert rules are tuned for your SLOs (see `config/prometheus/alerts.yaml`)
- [ ] Team knows the 30-second triage workflow (`bottleneck` → flame graph → fix)
- [ ] Grafana dashboards are bookmarked and accessible during incidents
- [ ] `diagnose --json` output is integrated with your incident tooling (PagerDuty, Slack, etc.)

---

## MTTR Targets

| Phase | Without Profiling | With Profiling | Tool |
|-------|-------------------|----------------|------|
| **Detection** | Alert fires (same) | Alert fires (same) | Prometheus alerts |
| **Triage** | 5-15 min (check metrics, logs, guess) | 30 sec (`bottleneck`) | `scripts/bottleneck.sh` |
| **Root cause** | 15-60 min (reproduce, debug, read code) | 2-5 min (flame graph) | Grafana + Pyroscope |
| **Verification** | Redeploy + wait + hope | Before/after flame graph diff | Before vs After dashboard |
| **Total MTTR** | 30-90 min | 5-15 min | — |

The key insight: profiling data is **already captured** when the incident happens. You don't need to reproduce anything — just look at the flame graph for the incident time window.

---

## CLI Quick Reference

| Command | What it does | When to use |
|---------|-------------|-------------|
| `bash scripts/run.sh bottleneck` | Automated root-cause per service | First response to any alert |
| `bash scripts/run.sh diagnose` | Full diagnostic (health + HTTP + profiles + alerts) | Comprehensive incident report |
| `bash scripts/run.sh top cpu` | Top CPU functions across all services | Identify CPU hotspots |
| `bash scripts/run.sh top memory` | Top allocators | Investigate GC pressure |
| `bash scripts/run.sh top mutex` | Top contended locks | Investigate lock contention |
| `bash scripts/run.sh health` | JVM health check with thresholds | Quick health scan |
| `bash scripts/run.sh compare` | Before/after load comparison | Verify a fix worked |
| `bash scripts/diagnose.sh --json` | Machine-readable diagnostic | Pipe to alerting, Slack, Jira |

---

## CI/CD Integration — TODO

Integrating profiling into CI pipelines to compare performance between builds:

- [ ] **Baseline snapshot script** (`scripts/ci-snapshot.sh`) — after a stable build, query Pyroscope API for per-service top-N function CPU/alloc/mutex shares, save to `baseline/profiles.json`. Commit as the known-good baseline
- [ ] **Regression gate script** (`scripts/ci-compare.sh`) — in the PR pipeline, deploy the new build, generate load, fetch the same top-N data, diff against baseline. Fail the pipeline if any function's share increased by > threshold (e.g. 20%)
- [ ] **GitHub Actions workflow** — `.github/workflows/profile-regression.yaml` that runs deploy → load → snapshot → compare → upload artifacts
- [ ] **Pyroscope diff API** — use `GET /pyroscope/render-diff?leftFrom=T1&leftUntil=T2&rightFrom=T3&rightUntil=T4` for server-side profile diffs without client-side math
- [ ] **PR comment bot** — post a summary table (service, function, baseline %, current %, delta) as a PR comment when regressions are detected
- [ ] **Artifact upload** — save flame graph SVGs or JSON diffs as CI artifacts attached to the build for review
- [ ] **Slack/webhook notification** — on regression detection, post a summary (service, function, % increase, link to Grafana) to the team channel
- [ ] **Scheduled baseline refresh** — weekly cron job that regenerates the baseline from the main branch to prevent baseline drift
