#!/usr/bin/env bash
set -eo pipefail

# Benchmarks bank services WITH and WITHOUT the Pyroscope agent to measure
# profiling overhead. Runs N requests against each service endpoint and
# reports average latency + throughput for both configurations.

REQUESTS="${1:-200}"
WARMUP="${2:-50}"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$PROJECT_DIR/.env"

# Load port assignments
if [ -f "$ENV_FILE" ]; then
  set -a; . "$ENV_FILE"; set +a
fi

GW="${API_GATEWAY_PORT:-18080}"
OR="${ORDER_SERVICE_PORT:-18081}"
PA="${PAYMENT_SERVICE_PORT:-18082}"
FR="${FRAUD_SERVICE_PORT:-18083}"
AC="${ACCOUNT_SERVICE_PORT:-18084}"
LO="${LOAN_SERVICE_PORT:-18085}"
NO="${NOTIFICATION_SERVICE_PORT:-18086}"

# Service definitions (no associative arrays — bash 3.2 compatible)
SVC_NAMES="api-gateway order-service payment-service fraud-service account-service loan-service notification-service"
SVC_URLS="http://localhost:${GW}/cpu http://localhost:${OR}/order/create http://localhost:${PA}/payment/transfer http://localhost:${FR}/fraud/score http://localhost:${AC}/account/interest http://localhost:${LO}/loan/amortize http://localhost:${NO}/notify/send"
SVC_HEALTH="http://localhost:${GW}/health http://localhost:${OR}/health http://localhost:${PA}/health http://localhost:${FR}/health http://localhost:${AC}/health http://localhost:${LO}/health http://localhost:${NO}/health"

RESULTS_DIR="$PROJECT_DIR/benchmark-results"
mkdir -p "$RESULTS_DIR"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

# ---------------------------------------------------------------------------
bench_run() {
  local label="$1"
  local outfile="$RESULTS_DIR/${TIMESTAMP}-${label}.csv"

  echo "service,endpoint,requests,errors,avg_ms,p50_ms,p95_ms,p99_ms,req_per_sec" > "$outfile"

  set -f
  local names=($SVC_NAMES)
  local urls=($SVC_URLS)
  set +f

  local idx=0
  for svc in "${names[@]}"; do
    local url="${urls[$idx]}"
    idx=$((idx + 1))

    # Warmup
    for i in $(seq 1 "$WARMUP"); do
      curl -sf -o /dev/null --max-time 10 "$url" 2>/dev/null || true
    done

    # Timed run — collect times in a temp file (bash 3.2 safe)
    local tmpfile
    tmpfile=$(mktemp)
    local errors=0

    for i in $(seq 1 "$REQUESTS"); do
      local t
      t=$(curl -sf -o /dev/null -w "%{time_total}" --max-time 15 "$url" 2>/dev/null) || { errors=$((errors + 1)); continue; }
      echo "$t * 1000" | bc 2>/dev/null >> "$tmpfile" || true
    done

    local count
    count=$(wc -l < "$tmpfile" | tr -d ' ')

    if [ "$count" -eq 0 ]; then
      echo "$svc,$url,$REQUESTS,$errors,0,0,0,0,0" >> "$outfile"
      rm -f "$tmpfile"
      continue
    fi

    # Sort and compute stats
    sort -g "$tmpfile" > "${tmpfile}.sorted"
    local sum
    sum=$(paste -sd+ "${tmpfile}.sorted" | bc)
    local avg
    avg=$(echo "scale=2; $sum / $count" | bc)
    local p50
    p50=$(sed -n "$((count * 50 / 100 + 1))p" "${tmpfile}.sorted")
    local p95
    p95=$(sed -n "$((count * 95 / 100 + 1))p" "${tmpfile}.sorted")
    local p99
    p99=$(sed -n "$((count * 99 / 100 + 1))p" "${tmpfile}.sorted")
    local total_sec
    total_sec=$(echo "scale=3; $sum / 1000" | bc)
    local rps=0
    if [ "$(echo "$total_sec > 0" | bc)" -eq 1 ]; then
      rps=$(echo "scale=1; $count / $total_sec" | bc)
    fi

    echo "$svc,$url,$REQUESTS,$errors,$avg,$p50,$p95,$p99,$rps" >> "$outfile"
    printf "  %-25s avg=%-8s p50=%-8s p95=%-8s p99=%-8s rps=%-6s errors=%s\n" \
           "$svc" "${avg}ms" "${p50}ms" "${p95}ms" "${p99}ms" "$rps" "$errors"

    rm -f "$tmpfile" "${tmpfile}.sorted"
  done

  echo ""
  echo "  Results saved to: $outfile"
}

# ---------------------------------------------------------------------------
wait_for_services() {
  set -f
  local health_urls=($SVC_HEALTH)
  set +f
  for url in "${health_urls[@]}"; do
    for attempt in $(seq 1 15); do
      curl -sf -o /dev/null "$url" 2>/dev/null && break
      sleep 2
    done
  done
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
docker compose down -v --remove-orphans > /dev/null 2>&1 || true
docker compose up -d > /dev/null 2>&1

echo "    Waiting for services to start..."
sleep 20
wait_for_services

echo "    Running benchmark..."
bench_run "with-pyroscope"
echo ""

# ---------------------------------------------------------------------------
# Phase 2: Benchmark WITHOUT Pyroscope
# ---------------------------------------------------------------------------
echo "--- Phase 2: WITHOUT Pyroscope agent ---"
echo "    Restarting services without profiling..."
docker compose down -v > /dev/null 2>&1
docker compose -f docker-compose.yml -f docker-compose.no-pyroscope.yml up -d > /dev/null 2>&1

echo "    Waiting for services to start..."
sleep 20
wait_for_services

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
docker compose down -v > /dev/null 2>&1
docker compose up -d > /dev/null 2>&1
echo "    Done. Services running with profiling enabled."
