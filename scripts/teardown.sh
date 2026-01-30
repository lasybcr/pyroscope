#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "==> Stopping and removing all containers, networks, and volumes..."
cd "$PROJECT_DIR"
docker compose down -v
echo "==> Done."
