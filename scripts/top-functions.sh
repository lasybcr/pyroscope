#!/usr/bin/env bash
set -euo pipefail

# Reports the top functions consuming CPU, memory, and mutex contention
# across all bank services using the Pyroscope HTTP API.
#
# Usage:
#   bash scripts/top-functions.sh                  # all services, all profiles
#   bash scripts/top-functions.sh cpu               # CPU only
#   bash scripts/top-functions.sh memory            # memory allocation only
#   bash scripts/top-functions.sh mutex             # mutex contention only
#   bash scripts/top-functions.sh cpu bank-api-gateway   # CPU for one service
#   bash scripts/top-functions.sh --top 20          # show top 20 (default 15)
#   bash scripts/top-functions.sh --user-code       # only show application code
#   bash scripts/top-functions.sh --filter io.vertx # only show io.vertx.* functions
#
# Requires: curl, python3, running Pyroscope instance

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_DIR/.env"

if [ -f "$ENV_FILE" ]; then
  set -a; . "$ENV_FILE"; set +a
fi

PYROSCOPE_URL="http://localhost:${PYROSCOPE_PORT:-4040}"
PROFILE_TYPE=""
SERVICE=""
TOP_N=15
TIME_RANGE="5m"
USER_CODE_ONLY=0
FILTER_PREFIX=""
APP_PREFIX="com.example."

# Parse arguments
while [ $# -gt 0 ]; do
  case "$1" in
    cpu|memory|mutex)
      PROFILE_TYPE="$1"
      ;;
    --top)
      shift
      TOP_N="${1:?--top requires a number}"
      if ! [[ "$TOP_N" =~ ^[0-9]+$ ]]; then
        echo "ERROR: --top must be a positive integer, got: $TOP_N"
        exit 1
      fi
      ;;
    --range)
      shift
      TIME_RANGE="${1:?--range requires a value like 1h, 30m}"
      if ! [[ "$TIME_RANGE" =~ ^[0-9]+[smhd]$ ]]; then
        echo "ERROR: --range must match format like 5m, 1h, 30s, got: $TIME_RANGE"
        exit 1
      fi
      ;;
    --user-code)
      USER_CODE_ONLY=1
      ;;
    --filter)
      shift
      FILTER_PREFIX="${1:?--filter requires a package prefix}"
      ;;
    bank-*)
      SERVICE="$1"
      ;;
    *)
      echo "Unknown argument: $1"
      echo "Usage: bash scripts/top-functions.sh [cpu|memory|mutex] [bank-SERVICE] [--top N] [--range TIME] [--user-code] [--filter PREFIX]"
      exit 1
      ;;
  esac
  shift
done

# Profile type mappings
CPU_PROFILE="process_cpu:cpu:nanoseconds:cpu:nanoseconds"
MEMORY_PROFILE="memory:alloc_in_new_tlab_bytes:bytes:space:bytes"
MUTEX_PROFILE="mutex:contentions:count:mutex:count"

# Determine which profiles to query
PROFILES=""
case "${PROFILE_TYPE:-all}" in
  cpu)    PROFILES="cpu" ;;
  memory) PROFILES="memory" ;;
  mutex)  PROFILES="mutex" ;;
  all)    PROFILES="cpu memory mutex" ;;
esac

# Discover services from Pyroscope
if [ -n "$SERVICE" ]; then
  SERVICES="$SERVICE"
else
  SERVICES=$(curl -sf "$PYROSCOPE_URL/querier.v1.QuerierService/LabelValues" \
    -X POST -H 'Content-Type: application/json' \
    -d '{"name":"service_name"}' 2>/dev/null \
    | jq -r '.names[]?' 2>/dev/null) || true
  if [ -z "$SERVICES" ]; then
    echo "ERROR: Cannot reach Pyroscope at $PYROSCOPE_URL or no services found."
    echo "Make sure the stack is running: bash scripts/run.sh"
    exit 1
  fi
fi

# Build parse_flamegraph.py arguments as array (SC2086)
PARSE_ARGS=("--top" "$TOP_N" "--app-prefix" "$APP_PREFIX")
if [ "$USER_CODE_ONLY" = "1" ]; then
  PARSE_ARGS+=("--user-code")
fi
if [ -n "$FILTER_PREFIX" ]; then
  PARSE_ARGS+=("--filter" "$FILTER_PREFIX")
fi

# Query and report
for profile in $PROFILES; do
  case "$profile" in
    cpu)    QUERY="$CPU_PROFILE";    LABEL="CPU";               UNIT="samples" ;;
    memory) QUERY="$MEMORY_PROFILE"; LABEL="Memory Allocation";  UNIT="bytes" ;;
    mutex)  QUERY="$MUTEX_PROFILE";  LABEL="Mutex Contention";   UNIT="count" ;;
  esac

  echo ""
  echo "================================================================"
  echo "  $LABEL — Top $TOP_N functions (last $TIME_RANGE)"
  echo "================================================================"

  for svc in $SERVICES; do
    echo ""
    echo "--- $svc ---"
    ENCODED_QUERY=$(printf '%s' "${QUERY}{service_name=\"${svc}\"}" | jq -sRr '@uri')
    RESULT=$(curl -sf "${PYROSCOPE_URL}/pyroscope/render?query=${ENCODED_QUERY}&from=now-${TIME_RANGE}&until=now&format=json" 2>/dev/null) || true
    if [ -z "$RESULT" ]; then
      echo "  (no data or Pyroscope unreachable)"
      continue
    fi
    echo "$RESULT" | PYTHONPATH="$SCRIPT_DIR/lib" python3 "$SCRIPT_DIR/lib/parse_flamegraph.py" --unit "$UNIT" "${PARSE_ARGS[@]}"
  done
done

echo ""
