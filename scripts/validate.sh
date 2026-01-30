#!/usr/bin/env bash
set -euo pipefail

# Validates the entire Pyroscope bank demo stack is working end-to-end.

PASS=0
FAIL=0
WARN=0

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
check "Pyroscope ready"    "curl -sf --retry 5 --retry-delay 3 --retry-all-errors http://localhost:4040/ready"
check "Prometheus ready"   "curl -sf --retry 3 --retry-delay 2 --retry-all-errors http://localhost:9090/-/ready"
check "Grafana health"     "curl -sf --retry 3 --retry-delay 2 --retry-all-errors http://localhost:3000/api/health"
echo ""

echo "2. Bank Services"
check "API Gateway :8080"      "curl -sf http://localhost:8080/health"
check "Order Service :8081"    "curl -sf http://localhost:8081/health"
check "Payment Service :8082"  "curl -sf http://localhost:8082/health"
check "Fraud Service :8083"    "curl -sf http://localhost:8083/health"
check "Account Service :8084"  "curl -sf http://localhost:8084/health"
check "Loan Service :8085"     "curl -sf http://localhost:8085/health"
check "Notification Svc :8086" "curl -sf http://localhost:8086/health"
echo ""

echo "3. Grafana Dashboards"
check "Pyroscope Overview"   "curl -sf -u admin:admin 'http://localhost:3000/api/dashboards/uid/pyroscope-java-overview'"
check "JVM Metrics"          "curl -sf -u admin:admin 'http://localhost:3000/api/dashboards/uid/jvm-metrics-deep-dive'"
check "HTTP Performance"     "curl -sf -u admin:admin 'http://localhost:3000/api/dashboards/uid/http-performance'"
check "Service Comparison"   "curl -sf -u admin:admin 'http://localhost:3000/api/dashboards/uid/service-comparison'"
echo ""

echo "4. Pyroscope Profiles (need load)"
warn_check "bank-api-gateway in Pyroscope"        "curl -sf 'http://localhost:4040/pyroscope/label-values?label=service_name' | grep bank-api-gateway"
warn_check "bank-payment-service in Pyroscope"     "curl -sf 'http://localhost:4040/pyroscope/label-values?label=service_name' | grep bank-payment-service"
warn_check "bank-fraud-service in Pyroscope"       "curl -sf 'http://localhost:4040/pyroscope/label-values?label=service_name' | grep bank-fraud-service"
echo ""

echo "5. API Gateway Endpoints"
check "/cpu"               "curl -sf http://localhost:8080/cpu"
check "/alloc"             "curl -sf http://localhost:8080/alloc"
check "/redis/set"         "curl -sf 'http://localhost:8080/redis/set?key=t&value=v'"
check "/json/process"      "curl -sf http://localhost:8080/json/process"
check "/batch/process"     "curl -sf --max-time 30 http://localhost:8080/batch/process"
echo ""

echo "6. Order Service"
check "/order/create"      "curl -sf http://localhost:8081/order/create"
check "/order/process"     "curl -sf --max-time 5 http://localhost:8081/order/process"
echo ""

echo "7. Payment Service"
check "/payment/transfer"   "curl -sf --max-time 5 http://localhost:8082/payment/transfer"
check "/payment/fx"         "curl -sf http://localhost:8082/payment/fx"
check "/payment/orchestrate" "curl -sf --max-time 5 http://localhost:8082/payment/orchestrate"
echo ""

echo "8. Fraud Service"
check "/fraud/score"       "curl -sf http://localhost:8083/fraud/score"
check "/fraud/ingest"      "curl -sf http://localhost:8083/fraud/ingest"
check "/fraud/anomaly"     "curl -sf --max-time 5 http://localhost:8083/fraud/anomaly"
echo ""

echo "9. Account Service"
check "/account/balance"   "curl -sf http://localhost:8084/account/balance"
check "/account/deposit"   "curl -sf --max-time 5 http://localhost:8084/account/deposit"
check "/account/interest"  "curl -sf --max-time 10 http://localhost:8084/account/interest"
echo ""

echo "10. Loan Service"
check "/loan/apply"        "curl -sf http://localhost:8085/loan/apply"
check "/loan/amortize"     "curl -sf --max-time 10 http://localhost:8085/loan/amortize"
check "/loan/risk-sim"     "curl -sf --max-time 10 http://localhost:8085/loan/risk-sim"
echo ""

echo "11. Notification Service"
check "/notify/send"       "curl -sf http://localhost:8086/notify/send"
check "/notify/bulk"       "curl -sf --max-time 10 http://localhost:8086/notify/bulk"
check "/notify/drain"      "curl -sf --max-time 10 http://localhost:8086/notify/drain"
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
