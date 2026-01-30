#!/usr/bin/env bash
set -euo pipefail

# Unified pipeline runner for the Pyroscope bank demo.
# Delegates to existing scripts — no duplicated logic.
#
# Usage:
#   bash scripts/run.sh                  # full pipeline (deploy + load + validate)
#   bash scripts/run.sh deploy           # deploy only
#   bash scripts/run.sh load 60          # 60s of load (foreground)
#   bash scripts/run.sh validate         # validate only
#   bash scripts/run.sh teardown         # clean up
#   bash scripts/run.sh benchmark        # profiling overhead test
#   bash scripts/run.sh --load-duration 60   # full pipeline with custom load duration
#
# In the full pipeline ("all"), load generation runs in the background so the
# pipeline is not blocked. After validation completes, load continues running
# to keep dashboards populated. Use "teardown" or Ctrl-C to stop.

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
    deploy|load|validate|teardown|benchmark|top|all)
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
# Cleanup handler — kill background load on exit
# ---------------------------------------------------------------------------
LOAD_PID=""
INTERRUPTED=0
cleanup() {
  if [ -n "$LOAD_PID" ] && kill -0 "$LOAD_PID" 2>/dev/null; then
    echo ""
    echo "Stopping background load generator (PID $LOAD_PID)..."
    # Kill the entire process group so child processes (curl, bash) also die
    kill -- -"$LOAD_PID" 2>/dev/null || kill "$LOAD_PID" 2>/dev/null || true
    wait "$LOAD_PID" 2>/dev/null || true
  fi
  if [ "$INTERRUPTED" -eq 1 ]; then
    echo "Interrupted. Services are still running."
    echo "Run 'bash scripts/run.sh teardown' to stop containers."
  fi
}
trap cleanup EXIT
trap 'INTERRUPTED=1; exit 130' INT TERM

# ---------------------------------------------------------------------------
# Stage runners
# ---------------------------------------------------------------------------
stage_deploy() {
  echo ""
  echo "===== [$1] Deploying ====="
  echo ""
  bash "$SCRIPT_DIR/deploy.sh"
}

stage_load_foreground() {
  echo ""
  echo "===== [$1] Generating load (${LOAD_DURATION}s) ====="
  echo ""
  bash "$SCRIPT_DIR/generate-load.sh" "$LOAD_DURATION"
}

stage_load_background() {
  echo ""
  echo "===== [$1] Starting background load (${LOAD_DURATION}s initial, then continuous) ====="
  echo ""
  # Run initial timed load, then keep generating indefinitely so dashboards stay populated.
  # The trap handler kills this on exit/teardown.
  # setsid creates a new process group so "kill -- -PID" kills all children.
  setsid bash -c "
    bash \"$SCRIPT_DIR/generate-load.sh\" \"$LOAD_DURATION\"
    echo ''
    echo '===== Initial load complete. Restarting continuous load (Ctrl-C or teardown to stop) ====='
    echo ''
    while true; do
      bash \"$SCRIPT_DIR/generate-load.sh\" 300 2>/dev/null || true
    done
  " &
  LOAD_PID=$!
  echo "Load generator running in background (PID $LOAD_PID)"
  # Wait for initial load to build up enough data for validation
  echo "Waiting ${LOAD_DURATION}s for initial load to complete..."
  sleep "$LOAD_DURATION"
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

stage_top() {
  echo ""
  echo "===== Top Functions (CPU / Memory / Mutex) ====="
  echo ""
  bash "$SCRIPT_DIR/top-functions.sh" "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}"
}

# ---------------------------------------------------------------------------
# Execute
# ---------------------------------------------------------------------------
case "$COMMAND" in
  all)
    stage_deploy          "1/3"
    stage_load_background "2/3"
    stage_validate        "3/3"
    echo ""
    echo "===== Pipeline complete ====="
    echo ""
    echo "Load generation continues in the background (PID $LOAD_PID)."
    echo "Dashboards will keep receiving data."
    echo "Run 'bash scripts/run.sh teardown' or press Ctrl-C to stop."
    echo ""
    # Keep the script alive so the background load continues.
    # Loop around wait so SIGINT can interrupt it.
    while kill -0 "$LOAD_PID" 2>/dev/null; do
      wait "$LOAD_PID" 2>/dev/null || break
    done
    ;;
  deploy)
    stage_deploy "1/1"
    ;;
  load)
    stage_load_foreground "1/1"
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
  top)
    stage_top
    ;;
  *)
    echo "Unknown command: $COMMAND"
    echo "Usage: bash scripts/run.sh [deploy|load|validate|teardown|benchmark|top|all] [--load-duration N]"
    exit 1
    ;;
esac
