#!/usr/bin/env bash
set -euo pipefail

# Validates the entire Pyroscope bank demo stack is working end-to-end.
# Designed to be fast — every curl has a short timeout so validation
# completes in under 30 seconds even if some endpoints are slow.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$(dirname "$SCRIPT_DIR")/.env"
[ -f "$ENV_FILE" ] && { set -a; source "$ENV_FILE"; set +a; }

PY="${PYROSCOPE_PORT:-4040}"
PM="${PROMETHEUS_PORT:-9090}"
GF="${GRAFANA_PORT:-3000}"
GW="${API_GATEWAY_PORT:-8080}"
OR="${ORDER_SERVICE_PORT:-8081}"
PA="${PAYMENT_SERVICE_PORT:-8082}"
FR="${FRAUD_SERVICE_PORT:-8083}"
AC="${ACCOUNT_SERVICE_PORT:-8084}"
LO="${LOAN_SERVICE_PORT:-8085}"
NO="${NOTIFICATION_SERVICE_PORT:-8086}"

GF_USER="${GRAFANA_ADMIN_USER:-admin}"
GF_PASS="${GRAFANA_ADMIN_PASSWORD:-admin}"

PASS=0
FAIL=0
WARN=0

# Default timeout for all curl calls (seconds)
T=5

# Check a URL is reachable (HTTP 200). No eval — curl is called directly.
check_url() {
  local name="$1"
  local url="$2"
  shift 2
  # Remaining args are extra curl flags (e.g. --retry, -u)
  if curl -sf --max-time "$T" "$@" "$url" > /dev/null 2>&1; then
    echo "  [PASS] $name"; ((PASS++)) || true
  else
    echo "  [FAIL] $name"; ((FAIL++)) || true
  fi
}

# Check a URL and grep for a pattern. WARN (not FAIL) if missing.
check_url_grep() {
  local name="$1"
  local url="$2"
  local pattern="$3"
  if curl -sf --max-time "$T" "$url" 2>/dev/null | grep -q "$pattern" 2>/dev/null; then
    echo "  [PASS] $name"; ((PASS++)) || true
  else
    echo "  [WARN] $name (may need more load time)"; ((WARN++)) || true
  fi
}

echo "=== Pyroscope Bank Enterprise Validation ==="
echo ""

echo "1. Infrastructure"
check_url "Pyroscope ready"    "http://localhost:${PY}/ready" --retry 3 --retry-delay 2 --retry-all-errors
check_url "Prometheus ready"   "http://localhost:${PM}/-/ready" --retry 3 --retry-delay 2 --retry-all-errors
check_url "Grafana health"     "http://localhost:${GF}/api/health" --retry 3 --retry-delay 2 --retry-all-errors
echo ""

echo "2. Bank Services"
check_url "API Gateway :${GW}"      "http://localhost:${GW}/health"
check_url "Order Service :${OR}"    "http://localhost:${OR}/health"
check_url "Payment Service :${PA}"  "http://localhost:${PA}/health"
check_url "Fraud Service :${FR}"    "http://localhost:${FR}/health"
check_url "Account Service :${AC}"  "http://localhost:${AC}/health"
check_url "Loan Service :${LO}"     "http://localhost:${LO}/health"
check_url "Notification Svc :${NO}" "http://localhost:${NO}/health"
echo ""

echo "3. Grafana Dashboards"
check_url "Pyroscope Overview"   "http://localhost:${GF}/api/dashboards/uid/pyroscope-java-overview" -u "${GF_USER}:${GF_PASS}"
check_url "JVM Metrics"          "http://localhost:${GF}/api/dashboards/uid/jvm-metrics-deep-dive" -u "${GF_USER}:${GF_PASS}"
check_url "HTTP Performance"     "http://localhost:${GF}/api/dashboards/uid/http-performance" -u "${GF_USER}:${GF_PASS}"
check_url "Service Comparison"   "http://localhost:${GF}/api/dashboards/uid/service-comparison" -u "${GF_USER}:${GF_PASS}"
echo ""

echo "4. Pyroscope Profiles (need load)"
check_url_grep "bank-api-gateway in Pyroscope"    "http://localhost:${PY}/pyroscope/label-values?label=service_name" "bank-api-gateway"
check_url_grep "bank-payment-service in Pyroscope" "http://localhost:${PY}/pyroscope/label-values?label=service_name" "bank-payment-service"
check_url_grep "bank-fraud-service in Pyroscope"   "http://localhost:${PY}/pyroscope/label-values?label=service_name" "bank-fraud-service"
echo ""

echo "5. API Gateway Endpoints"
check_url "/cpu"               "http://localhost:${GW}/cpu"
check_url "/alloc"             "http://localhost:${GW}/alloc"
check_url "/redis/set"         "http://localhost:${GW}/redis/set?key=t&value=v"
check_url "/json/process"      "http://localhost:${GW}/json/process"
check_url "/batch/process"     "http://localhost:${GW}/batch/process"
echo ""

echo "6. Order Service"
check_url "/order/create"      "http://localhost:${OR}/order/create"
check_url "/order/process"     "http://localhost:${OR}/order/process"
echo ""

echo "7. Payment Service"
check_url "/payment/transfer"   "http://localhost:${PA}/payment/transfer"
check_url "/payment/fx"         "http://localhost:${PA}/payment/fx"
check_url "/payment/orchestrate" "http://localhost:${PA}/payment/orchestrate"
echo ""

echo "8. Fraud Service"
check_url "/fraud/score"       "http://localhost:${FR}/fraud/score"
check_url "/fraud/ingest"      "http://localhost:${FR}/fraud/ingest"
check_url "/fraud/anomaly"     "http://localhost:${FR}/fraud/anomaly"
echo ""

echo "9. Account Service"
check_url "/account/balance"   "http://localhost:${AC}/account/balance"
check_url "/account/deposit"   "http://localhost:${AC}/account/deposit"
check_url "/account/interest"  "http://localhost:${AC}/account/interest"
echo ""

echo "10. Loan Service"
check_url "/loan/apply"        "http://localhost:${LO}/loan/apply"
check_url "/loan/amortize"     "http://localhost:${LO}/loan/amortize"
check_url "/loan/risk-sim"     "http://localhost:${LO}/loan/risk-sim"
echo ""

echo "11. Notification Service"
check_url "/notify/send"       "http://localhost:${NO}/notify/send"
check_url "/notify/bulk"       "http://localhost:${NO}/notify/bulk"
check_url "/notify/drain"      "http://localhost:${NO}/notify/drain"
echo ""

echo "=== Results ==="
echo "  Passed:   $PASS"
echo "  Failed:   $FAIL"
echo "  Warnings: $WARN"
echo ""
if [ "$FAIL" -gt 0 ]; then
  echo "VALIDATION FAILED — $FAIL check(s) did not pass."
  exit 1
else
  echo "VALIDATION PASSED"
  exit 0
fi
