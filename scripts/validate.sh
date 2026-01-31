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

PASS=0
FAIL=0
WARN=0

# Default timeout for all curl calls (seconds)
T=5

check() {
  local name="$1"; local cmd="$2"
  if eval "$cmd" > /dev/null 2>&1; then
    echo "  [PASS] $name"; ((PASS++)) || true
  else
    echo "  [FAIL] $name"; ((FAIL++)) || true
  fi
}

warn_check() {
  local name="$1"; local cmd="$2"
  if eval "$cmd" > /dev/null 2>&1; then
    echo "  [PASS] $name"; ((PASS++)) || true
  else
    echo "  [WARN] $name (may need more load time)"; ((WARN++)) || true
  fi
}

echo "=== Pyroscope Bank Enterprise Validation ==="
echo ""

echo "1. Infrastructure"
check "Pyroscope ready"    "curl -sf --max-time $T --retry 3 --retry-delay 2 --retry-all-errors http://localhost:${PY}/ready"
check "Prometheus ready"   "curl -sf --max-time $T --retry 3 --retry-delay 2 --retry-all-errors http://localhost:${PM}/-/ready"
check "Grafana health"     "curl -sf --max-time $T --retry 3 --retry-delay 2 --retry-all-errors http://localhost:${GF}/api/health"
echo ""

echo "2. Bank Services"
check "API Gateway :${GW}"      "curl -sf --max-time $T http://localhost:${GW}/health"
check "Order Service :${OR}"    "curl -sf --max-time $T http://localhost:${OR}/health"
check "Payment Service :${PA}"  "curl -sf --max-time $T http://localhost:${PA}/health"
check "Fraud Service :${FR}"    "curl -sf --max-time $T http://localhost:${FR}/health"
check "Account Service :${AC}"  "curl -sf --max-time $T http://localhost:${AC}/health"
check "Loan Service :${LO}"     "curl -sf --max-time $T http://localhost:${LO}/health"
check "Notification Svc :${NO}" "curl -sf --max-time $T http://localhost:${NO}/health"
echo ""

echo "3. Grafana Dashboards"
check "Pyroscope Overview"   "curl -sf --max-time $T -u admin:admin 'http://localhost:${GF}/api/dashboards/uid/pyroscope-java-overview'"
check "JVM Metrics"          "curl -sf --max-time $T -u admin:admin 'http://localhost:${GF}/api/dashboards/uid/jvm-metrics-deep-dive'"
check "HTTP Performance"     "curl -sf --max-time $T -u admin:admin 'http://localhost:${GF}/api/dashboards/uid/http-performance'"
check "Service Comparison"   "curl -sf --max-time $T -u admin:admin 'http://localhost:${GF}/api/dashboards/uid/service-comparison'"
echo ""

echo "4. Pyroscope Profiles (need load)"
warn_check "bank-api-gateway in Pyroscope"        "curl -sf --max-time $T 'http://localhost:${PY}/pyroscope/label-values?label=service_name' | grep bank-api-gateway"
warn_check "bank-payment-service in Pyroscope"     "curl -sf --max-time $T 'http://localhost:${PY}/pyroscope/label-values?label=service_name' | grep bank-payment-service"
warn_check "bank-fraud-service in Pyroscope"       "curl -sf --max-time $T 'http://localhost:${PY}/pyroscope/label-values?label=service_name' | grep bank-fraud-service"
echo ""

echo "5. API Gateway Endpoints"
check "/cpu"               "curl -sf --max-time $T http://localhost:${GW}/cpu"
check "/alloc"             "curl -sf --max-time $T http://localhost:${GW}/alloc"
check "/redis/set"         "curl -sf --max-time $T 'http://localhost:${GW}/redis/set?key=t&value=v'"
check "/json/process"      "curl -sf --max-time $T http://localhost:${GW}/json/process"
check "/batch/process"     "curl -sf --max-time $T http://localhost:${GW}/batch/process"
echo ""

echo "6. Order Service"
check "/order/create"      "curl -sf --max-time $T http://localhost:${OR}/order/create"
check "/order/process"     "curl -sf --max-time $T http://localhost:${OR}/order/process"
echo ""

echo "7. Payment Service"
check "/payment/transfer"   "curl -sf --max-time $T http://localhost:${PA}/payment/transfer"
check "/payment/fx"         "curl -sf --max-time $T http://localhost:${PA}/payment/fx"
check "/payment/orchestrate" "curl -sf --max-time $T http://localhost:${PA}/payment/orchestrate"
echo ""

echo "8. Fraud Service"
check "/fraud/score"       "curl -sf --max-time $T http://localhost:${FR}/fraud/score"
check "/fraud/ingest"      "curl -sf --max-time $T http://localhost:${FR}/fraud/ingest"
check "/fraud/anomaly"     "curl -sf --max-time $T http://localhost:${FR}/fraud/anomaly"
echo ""

echo "9. Account Service"
check "/account/balance"   "curl -sf --max-time $T http://localhost:${AC}/account/balance"
check "/account/deposit"   "curl -sf --max-time $T http://localhost:${AC}/account/deposit"
check "/account/interest"  "curl -sf --max-time $T http://localhost:${AC}/account/interest"
echo ""

echo "10. Loan Service"
check "/loan/apply"        "curl -sf --max-time $T http://localhost:${LO}/loan/apply"
check "/loan/amortize"     "curl -sf --max-time $T http://localhost:${LO}/loan/amortize"
check "/loan/risk-sim"     "curl -sf --max-time $T http://localhost:${LO}/loan/risk-sim"
echo ""

echo "11. Notification Service"
check "/notify/send"       "curl -sf --max-time $T http://localhost:${NO}/notify/send"
check "/notify/bulk"       "curl -sf --max-time $T http://localhost:${NO}/notify/bulk"
check "/notify/drain"      "curl -sf --max-time $T http://localhost:${NO}/notify/drain"
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
