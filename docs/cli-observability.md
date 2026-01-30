# CLI Observability — Programmatic Access Without the UI

How to diagnose, monitor, and debug Java services using the command line
and APIs — no browser required.

---

## Why CLI Access Matters

- **Incident response** — SSH into a box and get answers in seconds, no dashboard loading
- **Automation** — pipe JSON output into alerting, CI/CD gates, Slack bots, reports
- **Headless environments** — servers without a desktop, jump boxes, CI runners
- **Faster iteration** — run a command, see the result, adjust, repeat

---

## Quick Reference

| What you need | Command |
|---------------|---------|
| Full diagnostic report | `bash scripts/run.sh diagnose` |
| JSON output for scripting | `bash scripts/run.sh diagnose --json` |
| JVM health (all services) | `bash scripts/run.sh health` |
| CPU hotspot functions | `bash scripts/run.sh top cpu` |
| Memory allocation hotspots | `bash scripts/run.sh top memory` |
| Lock contention hotspots | `bash scripts/run.sh top mutex` |
| One service only | `bash scripts/diagnose.sh --service bank-api-gateway` |
| Only firing alerts | `bash scripts/diagnose.sh --section alerts` |
| Only HTTP stats | `bash scripts/diagnose.sh --section http` |

---

## The `diagnose` Command

A single command that queries Prometheus and Pyroscope to produce a complete
diagnostic report covering health, HTTP traffic, profiling hotspots, and alerts.

### Full report (human-readable)

```bash
bash scripts/run.sh diagnose
```

Output:

```
============================================================================
  Diagnostic Report — 2026-01-30T15:42:03
============================================================================
  Prometheus: http://localhost:9090
  Pyroscope:  http://localhost:4040

----------------------------------------------------------------------------
  JVM HEALTH
----------------------------------------------------------------------------
  [  OK  ] api-gateway
           CPU: 12.3%   Heap: 45/256 MB (17.6%)   GC: 0.0021 s/s   Threads: 22
  [ WARN ] payment-service
           CPU: 55.2%   Heap: 180/256 MB (70.3%)   GC: 0.0450 s/s   Threads: 28
           Issues: CPU warning, Heap warning, GC warning

----------------------------------------------------------------------------
  HTTP TRAFFIC
----------------------------------------------------------------------------
  Service                    Req/s    Err%    Avg Lat
  ------------------------- -------- ------- ----------
  api-gateway                  12.4    0.0%      23.5ms
  order-service                 8.1    0.0%      45.2ms
  payment-service               6.3    0.1%      89.7ms

  Slowest endpoints (avg latency, last 5m):
    1.    156.3ms  /loan/risk-sim
    2.    134.1ms  /payment/reconcile
    3.     98.2ms  /fraud/scan

----------------------------------------------------------------------------
  PROFILING HOTSPOTS (last 1h)
----------------------------------------------------------------------------
  bank-api-gateway
    CPU       42.3%  com.example.MainVerticle.fibonacci  (+4 more)
    Memory    18.5%  com.example.handlers.BatchHandler.processBatch  (+4 more)
    Mutex     (no data)

  bank-payment-service
    CPU       31.5%  com.example.PaymentVerticle.signTransaction  (+4 more)
    Memory    22.1%  com.example.PaymentVerticle.processPayroll  (+4 more)
    Mutex      8.3%  com.example.PaymentVerticle.processPayroll  (+4 more)

----------------------------------------------------------------------------
  FIRING ALERTS
----------------------------------------------------------------------------
  (none)
```

### JSON output for scripting

```bash
bash scripts/run.sh diagnose --json | jq .
```

Pipe into other tools:

```bash
# Get just the unhealthy services
bash scripts/diagnose.sh --json | jq '[.health[] | select(.status != "OK")]'

# Get top CPU function per service
bash scripts/diagnose.sh --json | jq '.profiles[] | {service, top_cpu: .cpu_top5[0]}'

# Check if any alerts are firing (exit code for CI)
bash scripts/diagnose.sh --json | jq -e '.alerts | length == 0' > /dev/null

# Get services with error rate > 1%
bash scripts/diagnose.sh --json | jq '[.http.services[] | select(.err_pct > 1)]'
```

### Filter by section

```bash
bash scripts/diagnose.sh --section health     # JVM health only
bash scripts/diagnose.sh --section http        # HTTP traffic only
bash scripts/diagnose.sh --section profiles    # profiling hotspots only
bash scripts/diagnose.sh --section alerts      # firing alerts only
```

### Filter by service

```bash
bash scripts/diagnose.sh --service bank-payment-service
bash scripts/diagnose.sh --service bank-fraud-service --json
```

---

## Existing CLI Tools

### `health` — Flag Problematic JVMs

```bash
bash scripts/run.sh health          # human-readable
bash scripts/run.sh health --json   # JSON for automation
```

Checks CPU, heap, GC, and thread count against thresholds:

| Metric | Warning | Critical |
|--------|---------|----------|
| CPU usage | >= 50% | >= 80% |
| Heap utilization | >= 70% | >= 85% |
| GC time rate | >= 0.03 s/s | >= 0.10 s/s |
| Live threads | >= 50 | >= 100 |

### `top` — CPU / Memory / Mutex Hotspot Functions

```bash
bash scripts/run.sh top                           # all profiles, all services
bash scripts/run.sh top cpu                       # CPU only
bash scripts/run.sh top memory                    # memory allocation only
bash scripts/run.sh top mutex                     # lock contention only
bash scripts/top-functions.sh cpu bank-api-gateway  # one service
bash scripts/top-functions.sh --top 20              # show top 20
bash scripts/top-functions.sh --range 30m           # last 30 minutes
```

---

## Direct API Access

For ad-hoc queries or building your own tooling.

### Prometheus API

```bash
# Instant query — CPU rate per service
curl -s 'http://localhost:9090/api/v1/query?query=rate(process_cpu_seconds_total{job="jvm"}[2m])' | python3 -m json.tool

# Heap usage per service
curl -s 'http://localhost:9090/api/v1/query?query=jvm_memory_used_bytes{job="jvm",area="heap"}' | python3 -m json.tool

# GC rate
curl -s 'http://localhost:9090/api/v1/query?query=rate(jvm_gc_collection_seconds_sum{job="jvm"}[2m])' | python3 -m json.tool

# HTTP request rate by endpoint
curl -s 'http://localhost:9090/api/v1/query?query=sum+by+(route)(rate(vertx_http_server_requests_total{job="vertx-apps"}[1m]))' | python3 -m json.tool

# Firing alerts
curl -s 'http://localhost:9090/api/v1/alerts' | python3 -c "
import json, sys
for a in json.load(sys.stdin)['data']['alerts']:
    if a['state'] == 'firing':
        print(f\"  {a['labels']['alertname']}: {a['labels'].get('instance','')}\")"

# Range query — CPU over last hour (for graphing)
curl -s 'http://localhost:9090/api/v1/query_range?query=rate(process_cpu_seconds_total{job="jvm"}[2m])&start='$(date -d '1 hour ago' +%s)'&end='$(date +%s)'&step=30s' | python3 -m json.tool
```

### Pyroscope API

```bash
# List all profiled services
curl -s 'http://localhost:4040/querier.v1.QuerierService/LabelValues' \
  -X POST -H 'Content-Type: application/json' \
  -d '{"name":"service_name"}'

# CPU profile as JSON (for parsing)
curl -s 'http://localhost:4040/pyroscope/render?query=process_cpu:cpu:nanoseconds:cpu:nanoseconds%7Bservice_name%3D%22bank-api-gateway%22%7D&from=now-1h&until=now&format=json' | python3 -m json.tool

# Memory allocation profile
curl -s 'http://localhost:4040/pyroscope/render?query=memory:alloc_in_new_tlab_bytes:bytes:space:bytes%7Bservice_name%3D%22bank-payment-service%22%7D&from=now-1h&until=now&format=json' | python3 -m json.tool

# Mutex contention profile
curl -s 'http://localhost:4040/pyroscope/render?query=mutex:contentions:count:mutex:count%7Bservice_name%3D%22bank-order-service%22%7D&from=now-1h&until=now&format=json' | python3 -m json.tool
```

---

## Incident Response — CLI Workflow

### Step 1: Get the full picture

```bash
bash scripts/run.sh diagnose
```

This tells you immediately: which services are unhealthy, what the HTTP traffic
looks like, which functions are hottest, and whether any alerts are firing.

### Step 2: Drill into the problem service

```bash
# Detailed health for one service
bash scripts/diagnose.sh --service bank-payment-service

# Top CPU functions for that service
bash scripts/top-functions.sh cpu bank-payment-service

# Top memory allocators
bash scripts/top-functions.sh memory bank-payment-service

# Lock contention
bash scripts/top-functions.sh mutex bank-payment-service
```

### Step 3: Check container logs

```bash
docker logs payment-service --tail 50
docker logs payment-service 2>&1 | grep -iE "error|exception|fatal"
```

### Step 4: Take action

```bash
# Restart the service
docker compose restart payment-service

# Re-check health after restart
bash scripts/run.sh health
```

---

## CI/CD Integration

### Gate deployments on JVM health

```bash
#!/bin/bash
# Run after deploy, fail pipeline if any service is critical
result=$(bash scripts/diagnose.sh --json --section health)
crits=$(echo "$result" | jq '[.health[] | select(.status == "CRITICAL")] | length')
if [ "$crits" -gt 0 ]; then
  echo "CRITICAL services detected after deploy:"
  echo "$result" | jq '.health[] | select(.status == "CRITICAL") | .service'
  exit 1
fi
```

### Capture baseline profiles

```bash
# Save diagnostic snapshot before and after a change
bash scripts/diagnose.sh --json > baseline.json
# ... make changes, redeploy ...
bash scripts/diagnose.sh --json > after.json

# Compare CPU of payment service
jq '.profiles[] | select(.service == "bank-payment-service") | .cpu_top5' baseline.json
jq '.profiles[] | select(.service == "bank-payment-service") | .cpu_top5' after.json
```

### Periodic health checks (cron)

```bash
# Add to crontab — check every 5 minutes, log unhealthy services
*/5 * * * * bash /path/to/scripts/diagnose.sh --json --section health | jq '[.health[] | select(.status != "OK")]' >> /var/log/jvm-health.jsonl
```
