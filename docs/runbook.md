# Operations Runbook

Complete operational guide for deploying, maintaining, and troubleshooting
the Pyroscope continuous profiling stack.

---

## Table of Contents

1. [Deployment](#deployment)
2. [Verification](#verification)
3. [Day-to-Day Operations](#day-to-day-operations)
4. [Incident Response Playbooks](#incident-response-playbooks)
5. [Maintenance](#maintenance)
6. [Configuration Reference](#configuration-reference)
7. [Troubleshooting](#troubleshooting)

---

## Deployment

### Prerequisites

| Requirement | Minimum | Recommended |
|-------------|---------|-------------|
| Docker | 20.10+ | 24+ |
| Docker Compose | v2 | v2.20+ |
| RAM | 8 GB | 16 GB |
| Disk | 4 GB | 10 GB |
| Ports | 3000, 4040, 8080-8086, 9090 free | |

### Option A: Bash Scripts (Recommended for first run)

```bash
# 1. Deploy
bash scripts/deploy.sh

# 2. Generate load (runs 5 minutes by default)
bash scripts/generate-load.sh

# 3. Validate
bash scripts/validate.sh

# 4. Tear down when done
bash scripts/teardown.sh
```

### Option B: Ansible

```bash
# Install the Docker collection
ansible-galaxy collection install community.docker

# Deploy
cd ansible
ansible-playbook -i inventory.yml deploy.yml

# Generate load
ansible-playbook -i inventory.yml generate-load.yml -e duration=120

# Tear down
ansible-playbook -i inventory.yml teardown.yml
```

For remote hosts, edit `ansible/inventory.yml`:

```yaml
all:
  hosts:
    staging:
      ansible_host: 10.0.1.50
      ansible_user: deploy
```

### Option C: Terraform

```bash
# Build the app image first (Terraform doesn't build images)
docker compose build

# Deploy infrastructure
cd terraform
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your project path
terraform init
terraform apply

# Tear down
terraform destroy
```

### Post-Deployment Checklist

- [ ] All 10 containers running (7 services + Pyroscope + Prometheus + Grafana): `docker compose ps`
- [ ] Pyroscope UI accessible: http://localhost:4040
- [ ] Grafana accessible: http://localhost:3000 (admin/admin)
- [ ] Prometheus targets up: http://localhost:9090/targets
- [ ] API Gateway health: `curl http://localhost:8080/health`
- [ ] Order Service health: `curl http://localhost:8081/health`
- [ ] Payment Service health: `curl http://localhost:8082/health`
- [ ] Fraud Service health: `curl http://localhost:8083/health`
- [ ] Account Service health: `curl http://localhost:8084/health`
- [ ] Loan Service health: `curl http://localhost:8085/health`
- [ ] Notification Service health: `curl http://localhost:8086/health`
- [ ] Run `bash scripts/validate.sh` for automated check

---

## Verification

### Automated Validation

```bash
bash scripts/validate.sh
```

This checks:
- All 10 services reachable (7 bank microservices + 3 infrastructure)
- Prometheus scraping all 7 application instances
- Prometheus alert rules loaded
- All 4 Grafana dashboards provisioned
- Both datasources (Pyroscope, Prometheus) provisioned
- Pyroscope receiving profile data from all 7 services (requires load)
- API Gateway endpoints responding
- Order Service endpoints responding
- Payment Service endpoints responding
- Fraud Service endpoints responding
- Account Service endpoints responding
- Loan Service endpoints responding
- Notification Service endpoints responding

### Manual Verification

```bash
# Services are up
docker compose ps

# Pyroscope has profile data
curl -s 'http://localhost:4040/pyroscope/label-values?label=service_name' | python3 -m json.tool
# Expected: ["bank-api-gateway", "bank-order-service", "bank-payment-service", "bank-fraud-service", "bank-account-service", "bank-loan-service", "bank-notification-service"]

# Prometheus is scraping
curl -s 'http://localhost:9090/api/v1/targets' | python3 -c "
import sys, json
data = json.load(sys.stdin)
for t in data['data']['activeTargets']:
    print(f\"  {t['labels'].get('job','?'):30} {t['labels'].get('instance','?'):25} {t['health']}\")"

# Grafana dashboards exist
curl -sf -u admin:admin 'http://localhost:3000/api/search?type=dash-db' | python3 -c "
import sys, json
for d in json.load(sys.stdin):
    print(f\"  {d['uid']:30} {d['title']}\")"
```

---

## Day-to-Day Operations

### Starting / Stopping

```bash
# Start (without rebuild)
docker compose up -d

# Stop (keep data)
docker compose stop

# Stop and remove volumes (clean slate)
docker compose down -v

# Rebuild after code changes
docker compose build --parallel && docker compose up -d
```

### Viewing Logs

```bash
# All services
docker compose logs -f

# Specific service
docker compose logs -f bank-api-gateway
docker compose logs -f bank-order-service
docker compose logs -f bank-payment-service
docker compose logs -f bank-fraud-service
docker compose logs -f bank-account-service
docker compose logs -f bank-loan-service
docker compose logs -f bank-notification-service
docker compose logs -f pyroscope

# Check for Pyroscope agent attachment on a specific service
docker compose logs bank-api-gateway 2>&1 | grep -i pyroscope
docker compose logs bank-order-service 2>&1 | grep -i pyroscope

# Check for errors across all services
docker compose logs --since 5m 2>&1 | grep -iE "error|exception|fatal"
```

### Restarting a Service

```bash
docker compose restart grafana
docker compose restart bank-api-gateway
docker compose restart bank-order-service
docker compose restart bank-payment-service
docker compose restart bank-fraud-service
docker compose restart bank-account-service
docker compose restart bank-loan-service
docker compose restart bank-notification-service
```

### Scaling (load testing)

```bash
# Run multiple load generators targeting all services
for i in 1 2 3; do
  bash scripts/generate-load.sh http://localhost:8080 http://localhost:8081 http://localhost:8082 http://localhost:8083 http://localhost:8084 http://localhost:8085 http://localhost:8086 300 &
done
```

---

## Incident Response Playbooks

### High CPU

**Alert:** `HighCpuUsage` fires when process CPU > 80% for 1 minute.

**Steps:**

1. Open Grafana → **Service Comparison** dashboard
   - Identify which of the 7 services has high CPU
2. Open **Pyroscope Overview** dashboard
   - Select the affected application (e.g., `bank-fraud-service`, `bank-order-service`)
   - CPU flame graph shows the hot methods
3. Look for:
   - Wide bars = methods consuming the most CPU
   - Deep recursive stacks (e.g., fraud detection algorithms)
   - Regex compilation inside loops
   - Serialization hotspots (JSON/XML building)
   - Loan amortization calculations in `bank-loan-service`
4. Use **comparison view** to diff against a known-good baseline
5. Cross-reference with **JVM Metrics** dashboard:
   - Is GC contributing to CPU? Check GC pause rate.
   - Is thread count abnormal?

**Common fixes:**
- Move CPU-bound work off event loop: `vertx.executeBlocking()`
- Pre-compile regex patterns
- Cache serialization results
- Replace recursive algorithms with iterative

---

### High Memory / GC Pressure

**Alert:** `HighHeapUsage` (heap > 85%) or `HighGcPauseRate` (GC > 50ms/s).

**Steps:**

1. **JVM Metrics** dashboard → Heap Memory panel
   - Is heap approaching max? Which service and pool?
2. **Pyroscope Overview** → Memory Allocation flame graph
   - Select the affected service (e.g., `bank-account-service`, `bank-payment-service`)
   - Which methods allocate the most?
3. Look for:
   - `byte[]` allocations in request handlers
   - Unbounded `ArrayList` or `HashMap` growth
   - String concatenation in loops (use `StringBuilder`)
   - Large temporary objects per request
   - Notification template rendering in `bank-notification-service`

**Common fixes:**
- Use object pooling for large buffers
- Pre-size collections: `new ArrayList<>(expectedSize)`
- Replace `String +=` with `StringBuilder`
- Increase heap: `-Xmx` in `JAVA_TOOL_OPTIONS`

---

### Lock Contention

**Symptoms:** High latency despite low CPU. Thread pool exhaustion.

**Steps:**

1. **JVM Metrics** → Thread Count panel
   - Are threads piling up on any service?
2. **Pyroscope Overview** → Lock Contention flame graph
   - Which `synchronized` blocks are contended?
3. Check specific services:
   - `bank-order-service` uses synchronized `processOrders()` — intentional for demo
   - `bank-payment-service` may show contention on shared payment state
   - `bank-account-service` may show contention on balance updates

**Common fixes:**
- Replace `synchronized` with `ConcurrentHashMap` or lock-free structures
- Use Vert.x `SharedData` instead of shared mutable state
- Move blocking calls to worker threads
- Use async database clients instead of JDBC

---

### Latency Spike

**Alert:** `HighLatency` fires when p99 > 2 seconds.

**Steps:**

1. **HTTP Performance** dashboard
   - Which service and endpoints have elevated latency?
   - Is it one service or multiple? (if API Gateway, downstream services may be the root cause)
2. Narrow the time range to the spike window
3. **Pyroscope Overview** — same time range
   - CPU flame graph: is computation the bottleneck?
   - Lock flame graph: is contention the bottleneck?
4. **JVM Metrics**: check GC pauses during the window
5. Check downstream dependencies:
   - `bank-api-gateway` (:8080) fans out to downstream services — check if latency originates there
   - `bank-payment-service` (:8082) may have external payment gateway latency
   - `bank-fraud-service` (:8083) may have expensive detection algorithms
   - `bank-notification-service` (:8086) may have slow dispatch

**Common fixes:**
- If CPU-bound: optimize hot methods or scale horizontally
- If lock-bound: reduce contention (see Lock Contention above)
- If GC-bound: reduce allocation rate (see High Memory above)
- If downstream: add timeouts, circuit breakers, caching

---

### Post-Deploy Regression

**Alert:** Any performance alert that fires shortly after a deployment.

**Steps:**

1. Pyroscope **comparison view** or Grafana Explore
2. Baseline: 1 hour before deploy
3. Comparison: 1 hour after deploy
4. Red flame graph segments = methods consuming more resources
5. Cross-reference with the deploy diff

**Automation:**

```bash
# Query Pyroscope API in CI/CD pipeline for any service
for svc in bank-api-gateway bank-order-service bank-payment-service bank-fraud-service bank-account-service bank-loan-service bank-notification-service; do
  curl -s "http://pyroscope:4040/pyroscope/render?\
query=process_cpu:cpu:nanoseconds:cpu:nanoseconds\
%7Bservice_name%3D%22${svc}%22%7D\
&from=now-1h&until=now&format=json" > "profile-${svc}.json"
done
# Compare against stored baselines
```

---

### Service Down

**Alert:** `ServiceDown` fires when Prometheus can't scrape an instance.

**Steps:**

```bash
# Check container status for all services
docker compose ps

# Check container logs for the affected service (replace with actual service name)
docker compose logs --tail 50 bank-api-gateway
docker compose logs --tail 50 bank-order-service
docker compose logs --tail 50 bank-payment-service
docker compose logs --tail 50 bank-fraud-service
docker compose logs --tail 50 bank-account-service
docker compose logs --tail 50 bank-loan-service
docker compose logs --tail 50 bank-notification-service

# Check if port is listening (example for each service)
docker compose exec bank-api-gateway sh -c "curl -sf http://localhost:8080/health"
docker compose exec bank-order-service sh -c "curl -sf http://localhost:8081/health"
docker compose exec bank-payment-service sh -c "curl -sf http://localhost:8082/health"
docker compose exec bank-fraud-service sh -c "curl -sf http://localhost:8083/health"
docker compose exec bank-account-service sh -c "curl -sf http://localhost:8084/health"
docker compose exec bank-loan-service sh -c "curl -sf http://localhost:8085/health"
docker compose exec bank-notification-service sh -c "curl -sf http://localhost:8086/health"

# Restart the affected service
docker compose restart bank-api-gateway
```

---

## Maintenance

### Updating Images

```bash
# Pull latest Pyroscope
docker compose pull pyroscope

# Rebuild app images after code changes
docker compose build --no-cache bank-api-gateway bank-order-service bank-payment-service bank-fraud-service bank-account-service bank-loan-service bank-notification-service

# Rolling restart
docker compose up -d
```

### Data Retention

Pyroscope and Prometheus store data in Docker volumes. To manage disk:

```bash
# Check volume sizes
docker system df -v | grep -E "pyroscope|prometheus|grafana"

# Remove all data (restart services after)
docker compose down -v
docker compose up -d
```

Pyroscope retention is configured in `config/pyroscope/pyroscope.yaml`.
Prometheus default retention is 15 days.

### Backup

```bash
# Export Grafana dashboards
for uid in pyroscope-java-overview jvm-metrics-deep-dive http-performance service-comparison; do
  curl -sf -u admin:admin "http://localhost:3000/api/dashboards/uid/$uid" | python3 -m json.tool > "backup-$uid.json"
done
```

---

## Configuration Reference

### Services

| Service | Image | Port | Config / Notes |
|---------|-------|------|----------------|
| Pyroscope | grafana/pyroscope:latest | 4040 | `config/pyroscope/pyroscope.yaml` |
| Prometheus | prom/prometheus:v2.53.0 | 9090 | `config/prometheus/prometheus.yml` |
| Grafana | grafana/grafana:11.1.0 | 3000 | `config/grafana/provisioning/` |
| API Gateway | built from `sample-app/` | 8080 | `JAVA_TOOL_OPTIONS` env var, routes to downstream services |
| Order Service | built from `sample-app/` | 8081 | `JAVA_TOOL_OPTIONS`, batch processing + synchronized blocks |
| Payment Service | built from `sample-app/` | 8082 | `JAVA_TOOL_OPTIONS`, payment processing simulation |
| Fraud Service | built from `sample-app/` | 8083 | `JAVA_TOOL_OPTIONS`, fraud detection algorithms |
| Account Service | built from `sample-app/` | 8084 | `JAVA_TOOL_OPTIONS`, account lookups and balance management |
| Loan Service | built from `sample-app/` | 8085 | `JAVA_TOOL_OPTIONS`, loan calculation and amortization |
| Notification Service | built from `sample-app/` | 8086 | `JAVA_TOOL_OPTIONS`, notification dispatch and templating |

### Grafana Dashboards

| Dashboard | UID | Purpose |
|-----------|-----|---------|
| Pyroscope Overview | `pyroscope-java-overview` | Flame graphs + JVM metrics |
| JVM Metrics Deep Dive | `jvm-metrics-deep-dive` | CPU, memory, GC, threads |
| HTTP Performance | `http-performance` | Request rate, latency, errors |
| Service Comparison | `service-comparison` | Side-by-side service comparison |

### Prometheus Alert Rules

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
| `pyroscope.application.name` | Service identifier (e.g., `bank-api-gateway`) | Groups profiles in UI |
| `pyroscope.server.address` | `http://pyroscope:4040` | Where to send profiles |
| `pyroscope.format` | `jfr` | Java Flight Recorder format |
| `pyroscope.profiler.event` | `cpu,alloc,lock` | What to profile |
| `pyroscope.profiler.alloc` | `512k` | Allocation sampling threshold |
| `pyroscope.labels.*` | key=value | Static labels for filtering |
| `pyroscope.upload.interval` | `10s` (default) | Profile upload frequency |

---

## Troubleshooting

### Profiles not appearing in Pyroscope

```bash
# 1. Verify agent loaded (check any service)
docker compose logs bank-api-gateway 2>&1 | grep -i "pyroscope\|async-profiler"
docker compose logs bank-order-service 2>&1 | grep -i "pyroscope\|async-profiler"

# 2. Check Pyroscope is receiving data
curl -s 'http://localhost:4040/pyroscope/label-values?label=service_name'

# 3. Check connectivity from app to Pyroscope
docker compose exec bank-api-gateway curl -sf http://pyroscope:4040/ready

# 4. Check JAVA_TOOL_OPTIONS is set
docker compose exec bank-api-gateway env | grep JAVA_TOOL_OPTIONS
```

### Grafana shows "No data"

1. Check time range — must include a period when load was running
2. Check datasource connectivity:
   ```bash
   curl -sf -u admin:admin 'http://localhost:3000/api/datasources/proxy/uid/pyroscope-ds/ready'
   ```
3. Restart Grafana to re-provision:
   ```bash
   docker compose restart grafana
   ```

### Build failures

```bash
# Clear Docker build cache
docker builder prune -f

# Rebuild from scratch
docker compose build --no-cache

# Check Docker resources
docker system info | grep -E "Memory|CPUs"
# Need at least 8GB RAM for building and running 7 services + infrastructure
```

### Port conflicts

```bash
# Check what's using the ports
ss -tlnp | grep -E '3000|4040|8080|8081|8082|8083|8084|8085|8086|9090'

# Change ports in docker-compose.yml if needed
# e.g., "3001:3000" to expose Grafana on 3001
```

### Container keeps restarting

```bash
# Check exit code
docker compose ps -a

# Check OOM kill (replace with the affected service name)
docker inspect bank-api-gateway | grep -i oom

# Add memory limit in docker-compose.yml:
# deploy:
#   resources:
#     limits:
#       memory: 512M
```
