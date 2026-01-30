# Demo Guide — Pyroscope Continuous Profiling

Step-by-step script for presenting this project. Works for live demos,
recorded walkthroughs, or self-guided exploration.

**Audience:** Engineers, SREs, platform teams evaluating continuous profiling.
**Duration:** 20-30 minutes.
**Prerequisites:** Docker and Docker Compose installed.

---

## Pre-Demo Setup

```bash
# Clean slate
bash scripts/teardown.sh 2>/dev/null || true

# Build and start everything
bash scripts/deploy.sh

# Start load generation in background
bash scripts/generate-load.sh http://localhost:8080 http://localhost:8081 http://localhost:8082 http://localhost:8083 http://localhost:8084 http://localhost:8085 http://localhost:8086 600 &
LOAD_PID=$!

# Wait 60 seconds for profiles to accumulate
sleep 60
```

---

## Act 1: The Problem — "Why is our service slow?"

### Talking Points
- Traditional debugging: add logging, reproduce locally, guess-and-check
- Continuous profiling: always-on, production-safe, no code changes
- Cost: <1% CPU overhead with async-profiler

### Demo Steps

1. **Open the app** — http://localhost:8080/health
   - "This is a bank API gateway built with Vert.x. No profiling code in the source."

2. **Show docker-compose.yml** — highlight `JAVA_TOOL_OPTIONS`
   - "The only change is this environment variable. The Pyroscope agent attaches via `-javaagent`. Zero code changes."

3. **Hit endpoints across the microservices**
   ```bash
   # API Gateway (routes and aggregates)
   curl http://localhost:8080/health

   # Order Service (batch processing, joins)
   curl http://localhost:8081/batch/process
   curl http://localhost:8081/db/join

   # Payment Service
   curl http://localhost:8082/health

   # Fraud Detection Service
   curl http://localhost:8083/health

   # Account Service
   curl http://localhost:8084/health

   # Loan Service
   curl http://localhost:8085/health

   # Notification Service
   curl http://localhost:8086/health
   ```
   - "These simulate real banking workloads — order processing, payment handling, fraud detection, account management, loan processing, and notifications."

---

## Act 2: Pyroscope UI — Finding Hot Methods

1. **Open Pyroscope** — http://localhost:4040

2. **Select application:** `bank-api-gateway`

3. **CPU flame graph**
   - Profile type: `process_cpu:cpu:nanoseconds:cpu:nanoseconds`
   - "Each bar is a method. Width = CPU time. The widest bars are your hot paths."
   - Point out: request routing, downstream fan-out, JSON serialization

4. **Memory allocation flame graph**
   - Switch to: `memory:alloc_in_new_tlab_bytes:bytes:space:bytes`
   - "Now we see where memory is being allocated. ArrayList growth, String splits, byte array allocations."

5. **Lock contention** (switch to Order Service)
   - Select: `bank-order-service`
   - Profile type: `lock:contentions:count:lock:count`
   - "The Order Service uses `synchronized` blocks. Under load, you can see contention."

6. **Compare services**
   - Use comparison view
   - Left: `{service_name="bank-api-gateway"}`
   - Right: `{service_name="bank-order-service"}`
   - "Red = more CPU on the right. Different code patterns produce visibly different profiles."

7. **Explore other services**
   - Select `bank-payment-service` — look for payment processing hotspots
   - Select `bank-fraud-service` — look for fraud detection algorithm CPU usage
   - Select `bank-account-service` — look for account lookup and balance computation
   - Select `bank-loan-service` — look for loan calculation and amortization methods
   - Select `bank-notification-service` — look for notification dispatch and templating

---

## Act 3: Grafana Dashboards — Unified Observability

### Dashboard 1: Pyroscope Overview
http://localhost:3000/d/pyroscope-java-overview

1. Show the **application selector** dropdown — all 7 services appear
2. CPU flame graph — same data as Pyroscope UI but embedded in Grafana
3. Memory and lock flame graphs below
4. Scroll down to **JVM metrics panels** — CPU, heap, GC, request rate
5. "Single pane of glass: profiles + metrics in one dashboard."

### Dashboard 2: JVM Metrics Deep Dive
http://localhost:3000/d/jvm-metrics-deep-dive

1. CPU gauge with thresholds (green/yellow/red)
2. Heap vs max memory — are we approaching limits?
3. GC pause duration and count — are pauses increasing?
4. Thread count — event loop saturation?
5. Memory pool utilization bar gauge — which pools are full?

### Dashboard 3: HTTP Performance
http://localhost:3000/d/http-performance

1. Request rate by endpoint — which endpoints are hit most?
2. p50/p95/p99 latency — where are the tail latencies?
3. Slowest endpoints bar chart — immediate visibility
4. Error rate panel — 5xx monitoring
5. "When latency spikes, switch to the Pyroscope flame graph for the same time window."

### Dashboard 4: Service Comparison
http://localhost:3000/d/service-comparison

1. Side-by-side CPU, heap, GC, threads, request rate for all 7 services
2. Side-by-side flame graphs at the bottom
3. "Different microservices produce different resource profiles."
4. "API Gateway: fan-out and routing overhead. Order Service: batch processing + synchronized = lock contention. Fraud Service: CPU-intensive detection algorithms. Payment Service: external call simulation. Account Service: data lookups. Loan Service: financial calculations. Notification Service: templating and dispatch."

---

## Act 4: Operational Workflow

### Scenario: "Latency spike on the payment service"

1. **Grafana HTTP Performance dashboard** — notice p99 spike on bank-payment-service
2. **Narrow the time range** to the spike window
3. **Switch to Pyroscope Overview** — same time range
4. **Select `bank-payment-service`** — CPU flame graph shows payment processing is hot
5. **Memory flame graph** — transaction object allocation is high
6. **Lock flame graph** — check for contention on shared payment state

"In production, this workflow takes 2 minutes instead of 2 hours."

### Scenario: "Fraud detection consuming too much CPU"

1. **Grafana Service Comparison dashboard** — `bank-fraud-service` CPU stands out
2. **Pyroscope Overview** — select `bank-fraud-service`
3. **CPU flame graph** — identify the fraud detection algorithm methods consuming CPU
4. **Compare with baseline** using comparison view

### Scenario: "Post-deploy regression"

1. Deploy a new version
2. In Pyroscope, use **comparison view**
3. Baseline: 1 hour before deploy. Comparison: 1 hour after.
4. Red methods = regression. Green = improvement.

---

## Act 5: Beyond the Demo

### What this proves
- Zero-code profiling works — no SDK, no annotations, no code changes
- Production-safe — <1% overhead with async-profiler
- Unified observability — profiles + metrics + dashboards in one stack
- Multi-service — compare all 7 bank microservices side by side

### How to adopt
1. Add Pyroscope to your infrastructure (single binary, or Helm chart)
2. Set `JAVA_TOOL_OPTIONS` in your deployments
3. Add the Pyroscope datasource to your existing Grafana
4. Done — profiles start flowing immediately

### Deployment options included in this repo
| Method | Command |
|--------|---------|
| Bash scripts | `bash scripts/deploy.sh` |
| Ansible | `ansible-playbook -i ansible/inventory.yml ansible/deploy.yml` |
| Terraform | `cd terraform && terraform apply` |

### API testing
Import `postman/pyroscope-demo.postman_collection.json` into Postman
for interactive exploration of all endpoints across all 7 services.

---

## Post-Demo Cleanup

```bash
# Stop load generator
kill $LOAD_PID 2>/dev/null || true

# Tear down
bash scripts/teardown.sh
```

---

## Troubleshooting During Demo

| Problem | Fix |
|---------|-----|
| No flame graph data | Load generator needs ~30s to produce profiles. Wait and refresh. |
| "No data" in Grafana panels | Check time range (top right). Set to "Last 1 hour". |
| Application selector empty | Pyroscope needs data first. Run load generator. |
| Dashboard not found | Grafana provisions on startup. Restart: `docker compose restart grafana` |
| Build fails | Check Docker has enough memory (8GB+ recommended for 7 services). Run `docker compose build --no-cache`. |

Run `bash scripts/validate.sh` to verify the full stack automatically.
