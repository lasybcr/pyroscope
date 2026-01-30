# Sample Queries for UI Debugging

Copy-paste these into the respective UIs to verify data is flowing.

---

## Pyroscope UI (http://localhost:4040)

### Application selector

After deploying and generating load, these application names should appear
in the Pyroscope UI dropdown:

- `bank-api-gateway` (API Gateway on :8080)
- `bank-order-service` (Order Service on :8081)
- `bank-payment-service` (Payment Service on :8082)
- `bank-fraud-service` (Fraud Detection Service on :8083)
- `bank-account-service` (Account Service on :8084)
- `bank-loan-service` (Loan Service on :8085)
- `bank-notification-service` (Notification Service on :8086)

### Profile type queries

Select an application, then use these profile types:

| Profile Type | What it shows |
|---|---|
| `process_cpu:cpu:nanoseconds:cpu:nanoseconds` | CPU flame graph — hot methods |
| `memory:alloc_in_new_tlab_bytes:bytes:space:bytes` | Allocation flame graph — where memory is allocated |
| `lock:contentions:count:lock:count` | Lock contention — synchronized blocks under contention |

### Label selectors (paste in "Label Selector" field)

```
{service_name="bank-api-gateway"}
```

```
{service_name="bank-order-service"}
```

```
{service_name="bank-payment-service"}
```

```
{service_name="bank-fraud-service"}
```

```
{service_name="bank-account-service"}
```

```
{service_name="bank-loan-service"}
```

```
{service_name="bank-notification-service"}
```

```
{service_name="bank-api-gateway", env="production"}
```

### Compare two services

1. Open Pyroscope UI → Comparison view
2. Left panel: `{service_name="bank-api-gateway"}`
3. Right panel: `{service_name="bank-order-service"}`
4. Profile type: `process_cpu:cpu:nanoseconds:cpu:nanoseconds`
5. Red = more CPU in right service, green = less

Other useful comparisons:
- `bank-payment-service` vs `bank-fraud-service` — payment processing vs fraud detection CPU patterns
- `bank-account-service` vs `bank-loan-service` — account lookups vs loan calculations
- `bank-api-gateway` vs `bank-notification-service` — routing overhead vs dispatch overhead

---

## Pyroscope HTTP API (curl)

### List all application names

```bash
curl -s 'http://localhost:4040/pyroscope/label-values?label=service_name' | python3 -m json.tool
```

### List all profile types

```bash
curl -s 'http://localhost:4040/pyroscope/label-values?label=__name__' | python3 -m json.tool
```

### Render CPU profile as JSON (last hour) — per service

```bash
# API Gateway
curl -s 'http://localhost:4040/pyroscope/render?query=process_cpu:cpu:nanoseconds:cpu:nanoseconds%7Bservice_name%3D%22bank-api-gateway%22%7D&from=now-1h&until=now&format=json' | python3 -m json.tool

# Order Service
curl -s 'http://localhost:4040/pyroscope/render?query=process_cpu:cpu:nanoseconds:cpu:nanoseconds%7Bservice_name%3D%22bank-order-service%22%7D&from=now-1h&until=now&format=json' | python3 -m json.tool

# Payment Service
curl -s 'http://localhost:4040/pyroscope/render?query=process_cpu:cpu:nanoseconds:cpu:nanoseconds%7Bservice_name%3D%22bank-payment-service%22%7D&from=now-1h&until=now&format=json' | python3 -m json.tool

# Fraud Service
curl -s 'http://localhost:4040/pyroscope/render?query=process_cpu:cpu:nanoseconds:cpu:nanoseconds%7Bservice_name%3D%22bank-fraud-service%22%7D&from=now-1h&until=now&format=json' | python3 -m json.tool

# Account Service
curl -s 'http://localhost:4040/pyroscope/render?query=process_cpu:cpu:nanoseconds:cpu:nanoseconds%7Bservice_name%3D%22bank-account-service%22%7D&from=now-1h&until=now&format=json' | python3 -m json.tool

# Loan Service
curl -s 'http://localhost:4040/pyroscope/render?query=process_cpu:cpu:nanoseconds:cpu:nanoseconds%7Bservice_name%3D%22bank-loan-service%22%7D&from=now-1h&until=now&format=json' | python3 -m json.tool

# Notification Service
curl -s 'http://localhost:4040/pyroscope/render?query=process_cpu:cpu:nanoseconds:cpu:nanoseconds%7Bservice_name%3D%22bank-notification-service%22%7D&from=now-1h&until=now&format=json' | python3 -m json.tool
```

### Render memory allocation profile

```bash
curl -s 'http://localhost:4040/pyroscope/render?query=memory:alloc_in_new_tlab_bytes:bytes:space:bytes%7Bservice_name%3D%22bank-api-gateway%22%7D&from=now-1h&until=now&format=json' | python3 -m json.tool
```

### Render lock contention profile

```bash
curl -s 'http://localhost:4040/pyroscope/render?query=lock:contentions:count:lock:count%7Bservice_name%3D%22bank-order-service%22%7D&from=now-1h&until=now&format=json' | python3 -m json.tool
```

---

## Grafana Explore (http://localhost:3000/explore)

### Pyroscope datasource queries

1. Go to Explore → select "Pyroscope" datasource
2. Use these queries:

**CPU profile for API Gateway:**
- Profile type: `process_cpu:cpu:nanoseconds:cpu:nanoseconds`
- Label selector: `{service_name="bank-api-gateway"}`

**CPU profile for Order Service:**
- Profile type: `process_cpu:cpu:nanoseconds:cpu:nanoseconds`
- Label selector: `{service_name="bank-order-service"}`

**Memory profile for Payment Service:**
- Profile type: `memory:alloc_in_new_tlab_bytes:bytes:space:bytes`
- Label selector: `{service_name="bank-payment-service"}`

**CPU profile for Fraud Service:**
- Profile type: `process_cpu:cpu:nanoseconds:cpu:nanoseconds`
- Label selector: `{service_name="bank-fraud-service"}`

**Memory profile for Account Service:**
- Profile type: `memory:alloc_in_new_tlab_bytes:bytes:space:bytes`
- Label selector: `{service_name="bank-account-service"}`

**CPU profile for Loan Service:**
- Profile type: `process_cpu:cpu:nanoseconds:cpu:nanoseconds`
- Label selector: `{service_name="bank-loan-service"}`

**Memory profile for Notification Service:**
- Profile type: `memory:alloc_in_new_tlab_bytes:bytes:space:bytes`
- Label selector: `{service_name="bank-notification-service"}`

**Lock contention (Order Service — has synchronized blocks):**
- Profile type: `lock:contentions:count:lock:count`
- Label selector: `{service_name="bank-order-service"}`

### Prometheus datasource queries

Switch to the "Prometheus" datasource in Explore, then paste:

**CPU usage rate per instance:**
```promql
rate(process_cpu_seconds_total{job="bank-app"}[1m])
```

**JVM heap memory by area:**
```promql
jvm_memory_used_bytes{job="bank-app", area="heap"}
```

**GC pause rate:**
```promql
rate(jvm_gc_pause_seconds_sum{job="bank-app"}[1m])
```

**HTTP request rate by endpoint:**
```promql
rate(http_server_requests_seconds_count{job="bank-app"}[1m])
```

**HTTP request latency p99:**
```promql
histogram_quantile(0.99, rate(http_server_requests_seconds_bucket{job="bank-app"}[5m]))
```

**Thread count:**
```promql
jvm_threads_live_threads{job="bank-app"}
```

**Classes loaded:**
```promql
jvm_classes_loaded_classes{job="bank-app"}
```

---

## Grafana Dashboard (http://localhost:3000/d/pyroscope-java-overview)

The provisioned dashboard has template variables at the top:

1. **application** — select any of the 7 services: `bank-api-gateway`, `bank-order-service`, `bank-payment-service`, `bank-fraud-service`, `bank-account-service`, `bank-loan-service`, `bank-notification-service`
2. **profile_type** — switch between CPU, memory, lock profiles
3. **comparison_range** — 15m, 30m, 1h, 3h, 6h for diff views

If panels show "No data":
- Verify load has been running for at least 30 seconds
- Check the time range picker (top right) is set to "Last 1 hour"
- Confirm the application variable matches a running service

---

## Quick Smoke Test (all curl)

Run these after `deploy.sh` + ~30s of `generate-load.sh`:

```bash
# 1. All 7 services responding
curl -sf http://localhost:8080/health && echo " api-gateway OK"
curl -sf http://localhost:8081/health && echo " order-service OK"
curl -sf http://localhost:8082/health && echo " payment-service OK"
curl -sf http://localhost:8083/health && echo " fraud-service OK"
curl -sf http://localhost:8084/health && echo " account-service OK"
curl -sf http://localhost:8085/health && echo " loan-service OK"
curl -sf http://localhost:8086/health && echo " notification-service OK"

# 2. Pyroscope receiving profiles from all services
curl -sf 'http://localhost:4040/pyroscope/label-values?label=service_name' | grep bank

# 3. Prometheus scraping metrics
curl -sf 'http://localhost:9090/api/v1/query?query=up' | grep bank

# 4. Grafana datasources provisioned
curl -sf -u admin:admin 'http://localhost:3000/api/datasources' | python3 -m json.tool | grep uid

# 5. Dashboard exists
curl -sf -u admin:admin 'http://localhost:3000/api/dashboards/uid/pyroscope-java-overview' | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'Dashboard: {d[\"dashboard\"][\"title\"]} — {len(d[\"dashboard\"][\"panels\"])} panels')"
```
