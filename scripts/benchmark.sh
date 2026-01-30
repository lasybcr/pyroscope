#!/usr/bin/env bash
set -euo pipefail

# Benchmarks bank services WITH and WITHOUT the Pyroscope agent to measure
# profiling overhead. Runs N requests against each service endpoint and
# reports average latency + throughput for both configurations.

REQUESTS="${1:-200}"
WARMUP="${2:-50}"
CONCURRENCY="${3:-4}"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# ---------------------------------------------------------------------------
# Endpoints to benchmark (one per service, representative workload)
# ---------------------------------------------------------------------------
declare -A ENDPOINTS=(
  ["api-gateway"]="http://localhost:8080/cpu"
  ["order-service"]="http://localhost:8081/order/create"
  ["payment-service"]="http://localhost:8082/payment/transfer"
  ["fraud-service"]="http://localhost:8083/fraud/score"
  ["account-service"]="http://localhost:8084/account/interest"
  ["loan-service"]="http://localhost:8085/loan/amortize"
  ["notification-service"]="http://localhost:8086/notify/send"
)

RESULTS_DIR="$PROJECT_DIR/benchmark-results"
mkdir -p "$RESULTS_DIR"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

# ---------------------------------------------------------------------------
bench_run() {
  local label="$1"
  local outfile="$RESULTS_DIR/${TIMESTAMP}-${label}.csv"

  echo "service,endpoint,requests,errors,avg_ms,p50_ms,p95_ms,p99_ms,req_per_sec" > "$outfile"

  for svc in "${!ENDPOINTS[@]}"; do
    local url="${ENDPOINTS[$svc]}"

    # Warmup (discard output)
    for i in $(seq 1 "$WARMUP"); do
      curl -sf -o /dev/null --max-time 10 "$url" 2>/dev/null || true
    done

    # Timed run
    local total_ms=0
    local errors=0
    local times=()

    for i in $(seq 1 "$REQUESTS"); do
      local t
      t=$(curl -sf -o /dev/null -w "%{time_total}" --max-time 15 "$url" 2>/dev/null) || { ((errors++)) || true; continue; }
      local ms
      ms=$(echo "$t * 1000" | bc 2>/dev/null || echo "0")
      times+=("$ms")
    done

    local count=${#times[@]}
    if [ "$count" -eq 0 ]; then
      echo "$svc,$url,$REQUESTS,$errors,0,0,0,0,0" >> "$outfile"
      continue
    fi

    # Sort times
    IFS=$'\n' sorted=($(sort -g <<<"${times[*]}")); unset IFS

    # Stats
    local sum=0
    for t in "${sorted[@]}"; do sum=$(echo "$sum + $t" | bc); done
    local avg=$(echo "scale=2; $sum / $count" | bc)
    local p50=${sorted[$(( count * 50 / 100 ))]}
    local p95=${sorted[$(( count * 95 / 100 ))]}
    local p99=${sorted[$(( count * 99 / 100 ))]}
    local total_sec=$(echo "scale=3; $sum / 1000" | bc)
    local rps
    if [ "$(echo "$total_sec > 0" | bc)" -eq 1 ]; then
      rps=$(echo "scale=1; $count / $total_sec" | bc)
    else
      rps=0
    fi

    echo "$svc,$url,$REQUESTS,$errors,$avg,$p50,$p95,$p99,$rps" >> "$outfile"
    printf "  %-25s avg=%-8s p50=%-8s p95=%-8s p99=%-8s rps=%-6s errors=%s\n" \
           "$svc" "${avg}ms" "${p50}ms" "${p95}ms" "${p99}ms" "$rps" "$errors"
  done

  echo ""
  echo "  Results saved to: $outfile"
}

# ---------------------------------------------------------------------------
# Phase 1: Benchmark WITH Pyroscope
# ---------------------------------------------------------------------------
echo "=== Pyroscope Performance Benchmark ==="
echo "    Requests per endpoint: $REQUESTS (warmup: $WARMUP)"
echo ""

echo "--- Phase 1: WITH Pyroscope agent ---"
echo "    Starting services with profiling enabled..."
cd "$PROJECT_DIR"
docker compose down --remove-orphans > /dev/null 2>&1 || true
docker compose up -d > /dev/null 2>&1

echo "    Waiting for services to start..."
sleep 20

# Verify services are up
for svc in "${!ENDPOINTS[@]}"; do
  url="${ENDPOINTS[$svc]}"
  host_url=$(echo "$url" | sed 's|/[^/]*$|/health|')
  for attempt in $(seq 1 15); do
    curl -sf -o /dev/null "$host_url" 2>/dev/null && break
    sleep 2
  done
done

echo "    Running benchmark..."
bench_run "with-pyroscope"
echo ""

# ---------------------------------------------------------------------------
# Phase 2: Benchmark WITHOUT Pyroscope
# ---------------------------------------------------------------------------
echo "--- Phase 2: WITHOUT Pyroscope agent ---"
echo "    Restarting services without profiling..."
docker compose down > /dev/null 2>&1
docker compose -f docker-compose.yml -f docker-compose.no-pyroscope.yml up -d > /dev/null 2>&1

echo "    Waiting for services to start..."
sleep 20

for svc in "${!ENDPOINTS[@]}"; do
  url="${ENDPOINTS[$svc]}"
  host_url=$(echo "$url" | sed 's|/[^/]*$|/health|')
  for attempt in $(seq 1 15); do
    curl -sf -o /dev/null "$host_url" 2>/dev/null && break
    sleep 2
  done
done

echo "    Running benchmark..."
bench_run "without-pyroscope"
echo ""

# ---------------------------------------------------------------------------
# Phase 3: Compare results
# ---------------------------------------------------------------------------
echo "--- Comparison ---"
WITH_FILE="$RESULTS_DIR/${TIMESTAMP}-with-pyroscope.csv"
WITHOUT_FILE="$RESULTS_DIR/${TIMESTAMP}-without-pyroscope.csv"

printf "  %-25s %-12s %-12s %-10s\n" "SERVICE" "WITH (avg)" "WITHOUT (avg)" "OVERHEAD"
printf "  %-25s %-12s %-12s %-10s\n" "-------" "----------" "-------------" "--------"

while IFS=, read -r svc url reqs errs avg p50 p95 p99 rps; do
  [ "$svc" = "service" ] && continue
  with_avg="$avg"

  without_avg=$(grep "^${svc}," "$WITHOUT_FILE" | cut -d, -f5)
  if [ -n "$without_avg" ] && [ "$(echo "$without_avg > 0" | bc)" -eq 1 ]; then
    overhead=$(echo "scale=1; (($with_avg - $without_avg) / $without_avg) * 100" | bc)
    printf "  %-25s %-12s %-12s %s%%\n" "$svc" "${with_avg}ms" "${without_avg}ms" "$overhead"
  else
    printf "  %-25s %-12s %-12s %s\n" "$svc" "${with_avg}ms" "N/A" "N/A"
  fi
done < "$WITH_FILE"

echo ""
echo "=== Benchmark complete ==="
echo "    Results in: $RESULTS_DIR/"
echo ""

# Restore services with Pyroscope
echo "    Restoring services with Pyroscope agent..."
docker compose down > /dev/null 2>&1
docker compose up -d > /dev/null 2>&1
echo "    Done. Services running with profiling enabled."
