#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Attach the Pyroscope Java agent to an EXISTING running JVM without restart.
# This uses the JVM Attach API via jattach.
#
# Usage:
#   ./attach-to-existing-jvm.sh <PID> [PYROSCOPE_SERVER_URL] [APP_NAME]
#
# Prerequisites:
#   - jattach (https://github.com/jattach/jattach) must be installed
#   - pyroscope.jar must be downloaded (the script will fetch it if missing)
# ---------------------------------------------------------------------------

PID="${1:?Usage: $0 <PID> [PYROSCOPE_SERVER_URL] [APP_NAME]}"
PYROSCOPE_URL="${2:-http://localhost:4040}"
APP_NAME="${3:-attached-java-app}"

AGENT_JAR="/opt/pyroscope/pyroscope.jar"

if [ ! -f "$AGENT_JAR" ]; then
  echo "==> Downloading Pyroscope Java agent..."
  mkdir -p /opt/pyroscope
  curl -fSL "https://github.com/grafana/pyroscope-java/releases/download/v0.14.0/pyroscope.jar" \
       -o "$AGENT_JAR"
fi

if ! command -v jattach &>/dev/null; then
  echo "ERROR: jattach is not installed. Install it from https://github.com/jattach/jattach"
  exit 1
fi

echo "==> Attaching Pyroscope agent to PID $PID ..."
jattach "$PID" load instrument false \
  "$AGENT_JAR=pyroscope.application.name=$APP_NAME,pyroscope.server.address=$PYROSCOPE_URL,pyroscope.format=jfr,pyroscope.profiler.event=cpu"

echo "==> Agent attached. Profiles will appear in Pyroscope shortly."
