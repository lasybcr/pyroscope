#!/usr/bin/env bash
set -euo pipefail

# Unified pipeline runner for the Pyroscope bank demo.
# Delegates to existing scripts — no duplicated logic.
#
# Usage:
#   bash scripts/run.sh                  # full pipeline (deploy + load + validate)
#   bash scripts/run.sh deploy           # deploy only
#   bash scripts/run.sh load 60          # 60s of load
#   bash scripts/run.sh validate         # validate only
#   bash scripts/run.sh teardown         # clean up
#   bash scripts/run.sh benchmark        # profiling overhead test
#   bash scripts/run.sh --load-duration 60   # full pipeline with custom load duration

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
COMMAND=""
LOAD_DURATION=120
EXTRA_ARGS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --load-duration)
      shift
      LOAD_DURATION="${1:?--load-duration requires a value}"
      ;;
    deploy|load|validate|teardown|benchmark|all)
      COMMAND="$1"
      ;;
    *)
      EXTRA_ARGS+=("$1")
      ;;
  esac
  shift
done

COMMAND="${COMMAND:-all}"

# If "load" was given with a positional arg, treat it as duration
if [ "$COMMAND" = "load" ] && [ ${#EXTRA_ARGS[@]} -gt 0 ]; then
  LOAD_DURATION="${EXTRA_ARGS[0]}"
fi

# ---------------------------------------------------------------------------
# Stage runners
# ---------------------------------------------------------------------------
stage_deploy() {
  echo ""
  echo "===== [$1] Deploying ====="
  echo ""
  bash "$SCRIPT_DIR/deploy.sh"
}

stage_load() {
  echo ""
  echo "===== [$1] Generating load (${LOAD_DURATION}s) ====="
  echo ""
  bash "$SCRIPT_DIR/generate-load.sh" "$LOAD_DURATION"
}

stage_validate() {
  echo ""
  echo "===== [$1] Validating ====="
  echo ""
  bash "$SCRIPT_DIR/validate.sh"
}

stage_teardown() {
  echo ""
  echo "===== Tearing down ====="
  echo ""
  bash "$SCRIPT_DIR/teardown.sh"
}

stage_benchmark() {
  echo ""
  echo "===== Running benchmark ====="
  echo ""
  bash "$SCRIPT_DIR/benchmark.sh" "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}"
}

# ---------------------------------------------------------------------------
# Execute
# ---------------------------------------------------------------------------
case "$COMMAND" in
  all)
    stage_deploy  "1/3"
    stage_load    "2/3"
    stage_validate "3/3"
    echo ""
    echo "===== Pipeline complete ====="
    ;;
  deploy)
    stage_deploy "1/1"
    ;;
  load)
    stage_load "1/1"
    ;;
  validate)
    stage_validate "1/1"
    ;;
  teardown)
    stage_teardown
    ;;
  benchmark)
    stage_benchmark
    ;;
  *)
    echo "Unknown command: $COMMAND"
    echo "Usage: bash scripts/run.sh [deploy|load|validate|teardown|benchmark|all] [--load-duration N]"
    exit 1
    ;;
esac
