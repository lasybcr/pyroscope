#!/usr/bin/env bash
set -euo pipefail

# Generates synthetic traffic against all bank microservices so that
# Pyroscope has profiling data to display.

DURATION_SECONDS="${1:-300}"

API_GW="http://localhost:8080"
ORDER="http://localhost:8081"
PAYMENT="http://localhost:8082"
FRAUD="http://localhost:8083"
ACCOUNT="http://localhost:8084"
LOAN="http://localhost:8085"
NOTIFY="http://localhost:8086"

echo "==> Bank Enterprise Load Generator (${DURATION_SECONDS}s)"
echo "    API Gateway :8080 | Order :8081 | Payment :8082 | Fraud :8083"
echo "    Account :8084 | Loan :8085 | Notification :8086"
echo "    Press Ctrl-C to stop early."
echo ""

END_TIME=$(($(date +%s) + DURATION_SECONDS))

hit() {
  curl -sf -o /dev/null -w "  %{http_code}  %{time_total}s  $1\n" "$1" --max-time 15 || true
}

while [ "$(date +%s)" -lt "$END_TIME" ]; do
  # API Gateway — mixed workloads (60% light, 30% medium, 10% heavy)
  ROLL=$((RANDOM % 100))
  if [ "$ROLL" -lt 60 ]; then
    EP=("/health" "/redis/get" "/redis/set" "/json/process" "/xml/process")
  elif [ "$ROLL" -lt 90 ]; then
    EP=("/cpu" "/alloc" "/db/select" "/csv/process" "/mixed")
  else
    EP=("/db/join" "/batch/process" "/downstream/fanout")
  fi
  hit "${API_GW}${EP[$((RANDOM % ${#EP[@]}))]}" &

  # Order Service
  OEPS=("/order/create" "/order/list" "/order/validate" "/order/process" "/order/aggregate" "/order/fulfill")
  hit "${ORDER}${OEPS[$((RANDOM % ${#OEPS[@]}))]}" &

  # Payment Service
  PEPS=("/payment/transfer" "/payment/fx" "/payment/orchestrate" "/payment/history" "/payment/payroll" "/payment/reconcile")
  hit "${PAYMENT}${PEPS[$((RANDOM % ${#PEPS[@]}))]}" &

  # Fraud Service
  FEPS=("/fraud/score" "/fraud/ingest" "/fraud/scan" "/fraud/anomaly" "/fraud/velocity" "/fraud/report")
  hit "${FRAUD}${FEPS[$((RANDOM % ${#FEPS[@]}))]}" &

  # Account Service
  AEPS=("/account/open" "/account/balance" "/account/deposit" "/account/withdraw" "/account/statement" "/account/interest" "/account/search" "/account/branch-summary")
  hit "${ACCOUNT}${AEPS[$((RANDOM % ${#AEPS[@]}))]}" &

  # Loan Service
  LEPS=("/loan/apply" "/loan/amortize" "/loan/risk-sim" "/loan/portfolio" "/loan/delinquency" "/loan/originate")
  hit "${LOAN}${LEPS[$((RANDOM % ${#LEPS[@]}))]}" &

  # Notification Service
  NEPS=("/notify/send" "/notify/bulk" "/notify/drain" "/notify/render" "/notify/status" "/notify/retry")
  hit "${NOTIFY}${NEPS[$((RANDOM % ${#NEPS[@]}))]}" &

  wait
  sleep "0.$((RANDOM % 3))"
done

echo ""
echo "==> Load generation complete. Check Pyroscope/Grafana for profiles."
