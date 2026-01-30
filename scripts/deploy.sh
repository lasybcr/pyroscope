#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "==> Building and starting all services..."
cd "$PROJECT_DIR"
docker compose build --parallel
docker compose up -d

echo ""
echo "==> Waiting for services to become healthy..."
for svc in pyroscope prometheus grafana api-gateway order-service payment-service fraud-service account-service loan-service notification-service; do
  printf "    %-25s" "$svc"
  for i in $(seq 1 30); do
    if docker compose ps "$svc" 2>/dev/null | grep -q "Up"; then
      echo "UP"
      break
    fi
    sleep 2
    if [ "$i" -eq 30 ]; then
      echo "TIMEOUT – check logs with: docker compose logs $svc"
    fi
  done
done

echo ""
echo "==> Bank Enterprise Services:"
echo "    Grafana:        http://localhost:3000  (admin/admin)"
echo "    Pyroscope:      http://localhost:4040"
echo "    Prometheus:     http://localhost:9090"
echo "    API Gateway:    http://localhost:8080"
echo "    Order Service:  http://localhost:8081"
echo "    Payment Svc:    http://localhost:8082"
echo "    Fraud Svc:      http://localhost:8083"
echo "    Account Svc:    http://localhost:8084"
echo "    Loan Svc:       http://localhost:8085"
echo "    Notification:   http://localhost:8086"
echo ""
echo "==> Generate load with:  bash scripts/generate-load.sh"
