#!/usr/bin/env bash
set -euo pipefail

# Unified pipeline runner for the Pyroscope bank demo.
# Delegates to existing scripts — no duplicated logic.
#
# Usage:
#   bash scripts/run.sh                  # full pipeline (quiet, with progress)
#   bash scripts/run.sh --verbose        # full pipeline (all output inline)
#   bash scripts/run.sh --log-dir DIR    # quiet mode + save logs to DIR
#   bash scripts/run.sh deploy           # deploy only (always verbose)
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
VERBOSE=0
LOG_DIR=""
EXTRA_ARGS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --verbose|-v)
      VERBOSE=1
      ;;
    --log-dir)
      shift
      LOG_DIR="${1:?--log-dir requires a path}"
      ;;
    --load-duration)
      shift
      LOAD_DURATION="${1:?--load-duration requires a value}"
      ;;
    deploy|load|validate|teardown|benchmark|top|health|diagnose|all)
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
# Quiet-mode helpers (used only for the "all" pipeline)
# ---------------------------------------------------------------------------

# Returns the output destination for a given stage.
# If --log-dir was given, returns a file path; otherwise /dev/null.
stage_output() {
  local name="$1"
  if [ -n "$LOG_DIR" ]; then
    echo "$LOG_DIR/${name}.log"
  else
    echo "/dev/null"
  fi
}

# Run a command with a spinner. On failure, re-runs to capture output for
# display (only when not using --log-dir, since we'd already have the log).
# Usage: run_stage <step> <label> <stage_name> <command...>
run_stage() {
  local step="$1" label="$2" stage_name="$3"
  shift 3
  local dest
  dest=$(stage_output "$stage_name")

  local start_time
  start_time=$(date +%s)

  # Run command in background, output to dest
  "$@" > "$dest" 2>&1 &
  local cmd_pid=$!

  local spin_chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
  local i=0

  while kill -0 "$cmd_pid" 2>/dev/null; do
    local elapsed=$(( $(date +%s) - start_time ))
    local c="${spin_chars:i%${#spin_chars}:1}"
    printf "\r  %s %s %s (%ds)" "$c" "[$step]" "$label" "$elapsed"
    i=$((i + 1))
    sleep 0.1
  done

  wait "$cmd_pid"
  local rc=$?

  local elapsed=$(( $(date +%s) - start_time ))
  if [ $rc -eq 0 ]; then
    printf "\r  ✔ [%s] %-40s done (%ds)\n" "$step" "$label" "$elapsed"
  else
    printf "\r  ✘ [%s] %-40s FAILED (%ds)\n" "$step" "$label" "$elapsed"
    echo ""
    if [ "$dest" != "/dev/null" ]; then
      echo "  See log: $dest"
      echo "  Last 20 lines:"
      echo ""
      tail -20 "$dest" | sed 's/^/    /'
    else
      # Re-run to capture output for display
      echo "  Re-running to capture error output..."
      echo ""
      "$@" 2>&1 | tail -20 | sed 's/^/    /' || true
    fi
    exit $rc
  fi
}

# Start background load, show spinner for the initial load duration.
run_load_stage_quiet() {
  local step="$1"
  local dest
  dest=$(stage_output "load")
  local start_time
  start_time=$(date +%s)

  (
    bash "$SCRIPT_DIR/generate-load.sh" "$LOAD_DURATION"
    while true; do
      bash "$SCRIPT_DIR/generate-load.sh" 300 2>/dev/null || true
    done
  ) > "$dest" 2>&1 &
  LOAD_PID=$!

  local spin_chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
  local i=0
  local waited=0

  while [ $waited -lt "$LOAD_DURATION" ]; do
    if ! kill -0 "$LOAD_PID" 2>/dev/null; then
      break
    fi
    local elapsed=$(( $(date +%s) - start_time ))
    local c="${spin_chars:i%${#spin_chars}:1}"
    printf "\r  %s [%s] Generating load (%d/%ds)..." "$c" "$step" "$elapsed" "$LOAD_DURATION"
    i=$((i + 1))
    sleep 1
    waited=$((waited + 1))
  done

  local elapsed=$(( $(date +%s) - start_time ))
  printf "\r  ✔ [%s] %-40s done (%ds)\n" "$step" "Generating load" "$elapsed"
}

# Poll Pyroscope and Prometheus to confirm data is available.
wait_for_data() {
  local step="$1"
  local start_time
  start_time=$(date +%s)
  local timeout=60
  local spin_chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
  local i=0
  local pyroscope_ok=0
  local prometheus_ok=0

  while true; do
    local elapsed=$(( $(date +%s) - start_time ))
    if [ $elapsed -ge $timeout ]; then
      printf "\r  ⚠ [%s] %-40s timeout (%ds)\n" "$step" "Waiting for data" "$elapsed"
      echo "  Data readiness check timed out. Services may still be starting."
      return 0  # non-fatal
    fi

    if [ $pyroscope_ok -eq 0 ]; then
      if curl -sf -X POST -H 'Content-Type: application/json' \
           -d '{"name":"service_name"}' \
           "http://localhost:4040/querier.v1.QuerierService/LabelValues" 2>/dev/null \
           | grep -q "bank-" 2>/dev/null; then
        pyroscope_ok=1
      fi
    fi

    if [ $prometheus_ok -eq 0 ]; then
      if curl -sf "http://localhost:9090/api/v1/query?query=jvm_memory_used_bytes" 2>/dev/null \
           | grep -q '"result"' 2>/dev/null; then
        prometheus_ok=1
      fi
    fi

    if [ $pyroscope_ok -eq 1 ] && [ $prometheus_ok -eq 1 ]; then
      local elapsed=$(( $(date +%s) - start_time ))
      printf "\r  ✔ [%s] %-40s done (%ds)\n" "$step" "Waiting for data" "$elapsed"
      return 0
    fi

    local c="${spin_chars:i%${#spin_chars}:1}"
    printf "\r  %s [%s] Waiting for data..." "$c" "$step"
    i=$((i + 1))
    sleep 2
  done
}

print_ready_banner() {
  echo ""
  echo "  ✔ Ready! Data is flowing to all dashboards."
  echo ""
  echo "    Grafana:    http://localhost:3000  (admin/admin)"
  echo "    Pyroscope:  http://localhost:4040"
  echo ""
  echo "    Quick commands:"
  echo "      bash scripts/run.sh health    # check JVM health"
  echo "      bash scripts/run.sh top       # top functions by CPU/memory/mutex"
  echo "      Ctrl-C to stop load · bash scripts/run.sh teardown to clean up"
  if [ -n "$LOG_DIR" ]; then
    echo ""
    echo "    Full logs: $LOG_DIR/"
  fi
  echo ""
}

# ---------------------------------------------------------------------------
# Cleanup handler — kill background load on exit
# ---------------------------------------------------------------------------
LOAD_PID=""
INTERRUPTED=0
cleanup() {
  if [ -n "$LOAD_PID" ] && kill -0 "$LOAD_PID" 2>/dev/null; then
    echo ""
    echo "Stopping background load generator (PID $LOAD_PID)..."
    kill "$LOAD_PID" 2>/dev/null || true
    pkill -P "$LOAD_PID" 2>/dev/null || true
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
# Stage runners (verbose mode / individual commands)
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
  (
    bash "$SCRIPT_DIR/generate-load.sh" "$LOAD_DURATION"
    echo ""
    echo "===== Initial load complete. Restarting continuous load (Ctrl-C or teardown to stop) ====="
    echo ""
    while true; do
      bash "$SCRIPT_DIR/generate-load.sh" 300 2>/dev/null || true
    done
  ) &
  LOAD_PID=$!
  echo "Load generator running in background (PID $LOAD_PID)"
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

stage_health() {
  echo ""
  echo "===== JVM Health Check ====="
  echo ""
  bash "$SCRIPT_DIR/jvm-health.sh" "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}"
}

# ---------------------------------------------------------------------------
# Execute
# ---------------------------------------------------------------------------
case "$COMMAND" in
  all)
    # Clean slate: full teardown (containers, volumes, local images, networks)
    # so every run is idempotent and starts fresh.
    bash "$SCRIPT_DIR/teardown.sh" >/dev/null 2>&1 || true

    if [ "$VERBOSE" -eq 1 ]; then
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
    else
      # Quiet mode: compact progress with spinners, output to /dev/null
      # Use --log-dir DIR to persist logs to disk
      if [ -n "$LOG_DIR" ]; then
        mkdir -p "$LOG_DIR"
      fi
      echo ""
      run_stage "1/4" "Deploying" "deploy" \
        bash "$SCRIPT_DIR/deploy.sh"

      run_load_stage_quiet "2/4"

      run_stage "3/4" "Validating" "validate" \
        bash "$SCRIPT_DIR/validate.sh"

      wait_for_data "4/4"

      print_ready_banner
    fi

    # Keep the script alive so the background load continues.
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
  health)
    stage_health
    ;;
  diagnose)
    bash "$SCRIPT_DIR/diagnose.sh" "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}"
    ;;
  *)
    echo "Unknown command: $COMMAND"
    echo "Usage: bash scripts/run.sh [deploy|load|validate|teardown|benchmark|top|health|diagnose|all] [--verbose] [--log-dir DIR] [--load-duration N]"
    exit 1
    ;;
esac
