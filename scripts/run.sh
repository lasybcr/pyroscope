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
#   bash scripts/run.sh --fixed              # deploy with OPTIMIZED=true (skip before phase)
#   bash scripts/run.sh compare              # before/after on running stack
#   bash scripts/run.sh dump-config          # dump running config to config/ directory
#
# In the full pipeline ("all"), load generation runs in the background so the
# pipeline is not blocked. After validation completes, load continues running
# to keep dashboards populated. Use "teardown" or Ctrl-C to stop.
#
# Commands safe to run alongside a running stack (read-only):
#   health, top, diagnose, bottleneck, validate, load, dump-config
#
# Commands that mutate the stack (will prompt for confirmation if running):
#   all (teardown + redeploy), deploy (recreate), compare (restart services),
#   teardown (stop all), benchmark (may restart)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load port assignments from .env if it exists (deploy.sh generates this).
# Provides defaults so the script works before the first deploy.
load_env() {
  if [ -f "$PROJECT_DIR/.env" ]; then
    set -a
    # shellcheck source=/dev/null
    . "$PROJECT_DIR/.env"
    set +a
  fi
}
load_env

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
COMMAND=""
LOAD_DURATION=120
VERBOSE=0
LOG_DIR=""
FIXED=0
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
    --fixed)
      FIXED=1
      ;;
    deploy|load|validate|teardown|benchmark|top|health|diagnose|compare|bottleneck|dump-config|all)
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

  setsid bash -c "
    bash '$SCRIPT_DIR/generate-load.sh' '$LOAD_DURATION'
    while true; do
      bash '$SCRIPT_DIR/generate-load.sh' 300 2>/dev/null || true
    done
  " > "$dest" 2>&1 &
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
           "http://localhost:${PYROSCOPE_PORT:-4040}/querier.v1.QuerierService/LabelValues" 2>/dev/null \
           | grep -q "bank-" 2>/dev/null; then
        pyroscope_ok=1
      fi
    fi

    if [ $prometheus_ok -eq 0 ]; then
      if curl -sf "http://localhost:${PROMETHEUS_PORT:-9090}/api/v1/query?query=jvm_memory_used_bytes" 2>/dev/null \
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
  local gport="${GRAFANA_PORT:-3000}"
  local pport="${PYROSCOPE_PORT:-4040}"
  echo ""
  echo "  ✔ Ready! Data is flowing to all dashboards."
  echo ""
  echo "    Grafana:    http://localhost:${gport}  (admin/admin)"
  echo "    Pyroscope:  http://localhost:${pport}"
  echo "    Before vs After: http://localhost:${gport}/d/before-after-comparison"
  echo ""
  echo "    Quick commands:"
  echo "      bash scripts/run.sh health    # check JVM health"
  echo "      bash scripts/run.sh top       # top functions by CPU/memory/mutex"
  echo "      bash scripts/run.sh compare   # before/after on running stack"
  echo "      Ctrl-C to stop load · bash scripts/run.sh teardown to clean up"
  if [ -n "$LOG_DIR" ]; then
    echo ""
    echo "    Full logs: $LOG_DIR/"
  fi
  echo ""
}

# ---------------------------------------------------------------------------
# Restart services with OPTIMIZED=true
# ---------------------------------------------------------------------------
restart_with_optimized() {
  echo "  Restarting all services with OPTIMIZED=true..."
  cd "$PROJECT_DIR"
  docker compose -f docker-compose.yml -f docker-compose.fixed.yml up -d --no-deps --build \
    api-gateway order-service payment-service fraud-service account-service loan-service notification-service
  # Wait for services to be healthy again
  for svc in api-gateway order-service payment-service fraud-service account-service loan-service notification-service; do
    for attempt in $(seq 1 30); do
      if docker compose ps "$svc" 2>/dev/null | grep -q "Up"; then
        break
      fi
      sleep 2
    done
  done
}

# ---------------------------------------------------------------------------
# Cleanup handler — kill background load on exit
# ---------------------------------------------------------------------------
LOAD_PID=""
INTERRUPTED=0
cleanup() {
  # Suppress all output from dying child processes
  exec 2>/dev/null

  if [ -n "$LOAD_PID" ]; then
    # Kill the entire process group: setsid session + generate-load.sh + all curls
    kill -- -"$LOAD_PID" 2>/dev/null || kill "$LOAD_PID" 2>/dev/null || true
    # Brief pause for processes to exit
    sleep 0.5 2>/dev/null || true
  fi

  # Restore stderr for final message
  exec 2>&1
  if [ "$INTERRUPTED" -eq 1 ]; then
    echo ""
    echo "Stopped. Services are still running."
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
  if [ "$FIXED" -eq 1 ]; then
    COMPOSE_EXTRA_FILES="docker-compose.fixed.yml" bash "$SCRIPT_DIR/deploy.sh"
  else
    bash "$SCRIPT_DIR/deploy.sh"
  fi
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
  setsid bash -c "
    bash '$SCRIPT_DIR/generate-load.sh' '$LOAD_DURATION'
    echo ''
    echo '===== Initial load complete. Restarting continuous load (Ctrl-C or teardown to stop) ====='
    echo ''
    while true; do
      bash '$SCRIPT_DIR/generate-load.sh' 300 2>/dev/null || true
    done
  " &
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
# Guard: warn if mutating command targets a running stack
# ---------------------------------------------------------------------------
# Commands that only read from the running stack (safe to run anytime):
#   dump-config, health, top, diagnose, bottleneck, validate, load
# Commands that mutate the stack (will restart/stop containers):
#   all, deploy, teardown, compare, benchmark

stack_is_running() {
  docker compose -f "$PROJECT_DIR/docker-compose.yml" ps --status running 2>/dev/null | grep -q "pyroscope" 2>/dev/null
}

case "$COMMAND" in
  all|deploy|compare)
    if stack_is_running; then
      echo ""
      echo "WARNING: Stack is already running."
      echo "  '$COMMAND' will modify running containers."
      echo ""
      case "$COMMAND" in
        all)     echo "  'all' tears down the entire stack and redeploys from scratch." ;;
        deploy)  echo "  'deploy' will recreate containers (may cause downtime)." ;;
        compare) echo "  'compare' will restart services with OPTIMIZED=true." ;;
      esac
      echo ""
      echo "  Safe commands for a running stack:"
      echo "    health, top, diagnose, bottleneck, validate, load, dump-config"
      echo ""
      read -r -p "  Continue? [y/N] " confirm
      case "$confirm" in
        [yY]|[yY][eE][sS]) ;;
        *)
          echo "  Aborted."
          exit 0
          ;;
      esac
    fi
    ;;
esac

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
      load_env
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
      if [ "$FIXED" -eq 1 ]; then
        run_stage "1/4" "Deploying (optimized)" "deploy" \
          env COMPOSE_EXTRA_FILES=docker-compose.fixed.yml bash "$SCRIPT_DIR/deploy.sh"
      else
        run_stage "1/4" "Deploying" "deploy" \
          bash "$SCRIPT_DIR/deploy.sh"
      fi

      # Reload .env now that deploy.sh has written actual port assignments.
      load_env

      run_load_stage_quiet "2/4"

      run_stage "3/4" "Validating" "validate" \
        bash "$SCRIPT_DIR/validate.sh"

      wait_for_data "4/4"

      print_ready_banner
    fi

    # Keep the script alive so the background load continues.
    # setsid makes LOAD_PID a session leader (not our child), so use
    # kill -0 polling instead of wait.
    while kill -0 "$LOAD_PID" 2>/dev/null; do
      sleep 2
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
  bottleneck)
    bash "$SCRIPT_DIR/bottleneck.sh" "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}"
    ;;
  compare)
    echo ""
    echo "===== Before vs After Comparison (on running stack) ====="
    echo ""
    echo "Phase 1: Generating load WITHOUT optimizations..."
    BEFORE_START=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    bash "$SCRIPT_DIR/generate-load.sh" "$LOAD_DURATION"
    BEFORE_END=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    echo ""
    echo "Phase 2: Restarting with OPTIMIZED=true..."
    restart_with_optimized
    echo ""
    echo "Phase 2: Generating load WITH optimizations..."
    AFTER_START=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    bash "$SCRIPT_DIR/generate-load.sh" "$LOAD_DURATION"
    AFTER_END=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    echo ""
    echo "===== Comparison complete ====="
    echo "  Before: $BEFORE_START → $BEFORE_END"
    echo "  After:  $AFTER_START → $AFTER_END"
    echo "  Open Grafana → Before vs After Fix dashboard"
    echo "  Set 'Before' panel time to Phase 1 range, 'After' panel to Phase 2 range"
    echo ""
    ;;
  diagnose)
    bash "$SCRIPT_DIR/diagnose.sh" "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}"
    ;;
  dump-config)
    # Dump the running config from each infrastructure container into
    # a timestamped snapshot directory. Never overwrites repo defaults.
    DUMP_DIR="$PROJECT_DIR/config-snapshots/$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$DUMP_DIR"

    echo ""
    echo "===== Dumping Running Configuration ====="
    echo "  Snapshot directory: $DUMP_DIR"
    echo ""

    # Pyroscope: read config from running container
    echo "--- Pyroscope ---"
    PYRO_CONFIG=$(docker exec pyroscope cat /etc/pyroscope/pyroscope.yaml 2>/dev/null) || true
    if [ -n "$PYRO_CONFIG" ]; then
      echo "$PYRO_CONFIG"
      echo "$PYRO_CONFIG" > "$DUMP_DIR/pyroscope.yaml"
      echo ""
      echo "  → $DUMP_DIR/pyroscope.yaml"
    else
      echo "  (container not running or config not found)"
    fi
    echo ""

    # Prometheus: dump resolved config via API
    echo "--- Prometheus ---"
    PROM_URL="http://localhost:${PROMETHEUS_PORT:-9090}"
    PROM_CONFIG=$(curl -sf "$PROM_URL/api/v1/status/config" 2>/dev/null \
      | jq -r '.data.yaml // empty' 2>/dev/null) || true
    if [ -n "$PROM_CONFIG" ]; then
      echo "$PROM_CONFIG"
      echo "$PROM_CONFIG" > "$DUMP_DIR/prometheus.yml"
      echo ""
      echo "  → $DUMP_DIR/prometheus.yml"
    else
      echo "  (Prometheus not reachable at $PROM_URL)"
    fi
    echo ""

    # Grafana: dump datasources via API
    echo "--- Grafana Datasources ---"
    GF_URL="http://localhost:${GRAFANA_PORT:-3000}"
    GF_DS=$(curl -sf -u admin:admin "$GF_URL/api/datasources" 2>/dev/null) || true
    if [ -n "$GF_DS" ]; then
      echo "$GF_DS" | jq .
      echo "$GF_DS" | jq . > "$DUMP_DIR/grafana-datasources.json"
      echo ""
      echo "  → $DUMP_DIR/grafana-datasources.json"
    else
      echo "  (Grafana not reachable at $GF_URL)"
    fi
    echo ""

    # .env (port assignments)
    if [ -f "$PROJECT_DIR/.env" ]; then
      cp "$PROJECT_DIR/.env" "$DUMP_DIR/env"
      echo "--- .env (port assignments) ---"
      cat "$PROJECT_DIR/.env"
      echo ""
      echo "  → $DUMP_DIR/env"
      echo ""
    fi

    echo "===== Snapshot saved to $DUMP_DIR ====="
    echo ""
    echo "  To use this snapshot instead of repo defaults:"
    echo ""
    echo "    # Pyroscope"
    echo "    cp $DUMP_DIR/pyroscope.yaml config/pyroscope/pyroscope.yaml"
    echo ""
    echo "    # Prometheus"
    echo "    cp $DUMP_DIR/prometheus.yml config/prometheus/prometheus.yml"
    echo ""
    echo "    # Port assignments"
    echo "    cp $DUMP_DIR/env .env"
    echo ""
    echo "    # Then redeploy"
    echo "    bash scripts/run.sh teardown && bash scripts/run.sh"
    echo ""
    echo "  Or diff against current config:"
    echo "    diff config/pyroscope/pyroscope.yaml $DUMP_DIR/pyroscope.yaml"
    echo "    diff config/prometheus/prometheus.yml $DUMP_DIR/prometheus.yml"
    echo ""
    ;;
  *)
    echo "Unknown command: $COMMAND"
    echo "Usage: bash scripts/run.sh [deploy|load|validate|teardown|benchmark|top|health|diagnose|compare|bottleneck|dump-config|all] [--verbose] [--log-dir DIR] [--load-duration N] [--fixed]"
    exit 1
    ;;
esac
