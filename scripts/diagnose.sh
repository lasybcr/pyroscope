#!/usr/bin/env bash
set -euo pipefail

# Full diagnostic report for all Java bank services.
# Queries Prometheus (JVM metrics, HTTP stats) and Pyroscope (profiling hotspots)
# programmatically — no browser required.
#
# Usage:
#   bash scripts/diagnose.sh                  # full report, all services
#   bash scripts/diagnose.sh --service bank-api-gateway   # one service only
#   bash scripts/diagnose.sh --json           # machine-readable JSON output
#   bash scripts/diagnose.sh --section health # only health section
#   bash scripts/diagnose.sh --section http   # only HTTP stats
#   bash scripts/diagnose.sh --section profiles # only profiling hotspots
#   bash scripts/diagnose.sh --section alerts  # only firing alerts
#
# Sections: health, http, profiles, alerts, all (default)
#
# Requires: curl, python3, running Prometheus + Pyroscope instances

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_DIR/.env"

if [ -f "$ENV_FILE" ]; then
  set -a; . "$ENV_FILE"; set +a
fi

PROMETHEUS_URL="http://localhost:${PROMETHEUS_PORT:-9090}"
PYROSCOPE_URL="http://localhost:${PYROSCOPE_PORT:-4040}"
JSON_MODE=0
SECTION="all"
SERVICE_FILTER=""

while [ $# -gt 0 ]; do
  case "$1" in
    --json) JSON_MODE=1 ;;
    --section)
      shift
      SECTION="${1:?--section requires a value: health, http, profiles, alerts, all}"
      ;;
    --service)
      shift
      SERVICE_FILTER="${1:?--service requires a service name like bank-api-gateway}"
      ;;
    *)
      echo "Unknown argument: $1"
      echo "Usage: bash scripts/diagnose.sh [--json] [--section health|http|profiles|alerts|all] [--service bank-SERVICE]"
      exit 1
      ;;
  esac
  shift
done

# ---------------------------------------------------------------------------
# Verify stack is reachable
# ---------------------------------------------------------------------------
PROM_OK=0
PYRO_OK=0
if curl -sf "$PROMETHEUS_URL/-/ready" > /dev/null 2>&1; then PROM_OK=1; fi
if curl -sf "$PYROSCOPE_URL/ready" > /dev/null 2>&1; then PYRO_OK=1; fi

if [ $PROM_OK -eq 0 ] && [ $PYRO_OK -eq 0 ]; then
  echo "ERROR: Cannot reach Prometheus ($PROMETHEUS_URL) or Pyroscope ($PYROSCOPE_URL)"
  echo "Make sure the stack is running: bash scripts/run.sh"
  exit 1
fi

# ---------------------------------------------------------------------------
# Python diagnostic engine
# ---------------------------------------------------------------------------
DIAG_SCRIPT='
import json, sys, urllib.request, urllib.parse, urllib.error
from datetime import datetime

prometheus = sys.argv[1]
pyroscope = sys.argv[2]
prom_ok = sys.argv[3] == "1"
pyro_ok = sys.argv[4] == "1"
json_mode = sys.argv[5] == "1"
section = sys.argv[6]
service_filter = sys.argv[7] if len(sys.argv) > 7 else ""

# ---- helpers ----

def prom_query(expr):
    if not prom_ok:
        return []
    url = f"{prometheus}/api/v1/query?query={urllib.parse.quote(expr)}"
    try:
        resp = urllib.request.urlopen(url, timeout=10)
        data = json.loads(resp.read())
        return data.get("data", {}).get("result", [])
    except Exception:
        return []

def prom_instant(expr):
    """Return {label: float} from instant query, keyed by instance (service name part)."""
    out = {}
    for r in prom_query(expr):
        inst = r["metric"].get("instance", "unknown").split(":")[0]
        out[inst] = float(r["value"][1])
    return out

def pyro_labels():
    if not pyro_ok:
        return []
    try:
        req = urllib.request.Request(
            f"{pyroscope}/querier.v1.QuerierService/LabelValues",
            data=json.dumps({"name": "service_name"}).encode(),
            headers={"Content-Type": "application/json"},
            method="POST"
        )
        resp = urllib.request.urlopen(req, timeout=10)
        return json.loads(resp.read()).get("names", [])
    except Exception:
        return []

def pyro_top_functions(svc, profile_id, n=5):
    if not pyro_ok:
        return []
    query = f"{profile_id}{{service_name=\"{svc}\"}}"
    url = f"{pyroscope}/pyroscope/render?query={urllib.parse.quote(query)}&from=now-1h&until=now&format=json"
    try:
        resp = urllib.request.urlopen(url, timeout=10)
        data = json.loads(resp.read())
    except Exception:
        return []

    fb = data.get("flamebearer", {})
    names = fb.get("names", [])
    levels = fb.get("levels", [])
    total = fb.get("numTicks", 0)
    if total == 0:
        return []

    self_map = {}
    for level in levels:
        i = 0
        while i + 3 < len(level):
            name_idx = level[i + 3]
            self_val = level[i + 2]
            if name_idx < len(names) and self_val > 0:
                self_map[names[name_idx]] = self_map.get(names[name_idx], 0) + self_val
            i += 4

    top = sorted(self_map.items(), key=lambda x: -x[1])[:n]
    return [{"function": name, "self": val, "pct": round(val / total * 100, 1)} for name, val in top]

# ---- service name mapping ----

SVC_MAP = {
    "api-gateway": "bank-api-gateway",
    "order-service": "bank-order-service",
    "payment-service": "bank-payment-service",
    "fraud-service": "bank-fraud-service",
    "account-service": "bank-account-service",
    "loan-service": "bank-loan-service",
    "notification-service": "bank-notification-service",
}
REVERSE_MAP = {v: k for k, v in SVC_MAP.items()}

# ---- collect all data ----

report = {
    "timestamp": datetime.now().isoformat(timespec="seconds"),
    "sources": {
        "prometheus": prometheus if prom_ok else None,
        "pyroscope": pyroscope if pyro_ok else None,
    },
}

# Discover services
prom_services = sorted(set(prom_instant("up{job=\"jvm\"}").keys()))
pyro_services = pyro_labels()

if service_filter:
    container_name = REVERSE_MAP.get(service_filter, service_filter)
    prom_services = [s for s in prom_services if s == container_name]
    pyro_services = [s for s in pyro_services if s == service_filter]

# ---- SECTION: health ----

def collect_health():
    cpu = prom_instant("rate(process_cpu_seconds_total{job=\"jvm\"}[2m])")
    heap_used = prom_instant("jvm_memory_used_bytes{job=\"jvm\", area=\"heap\"}")
    heap_max = prom_instant("jvm_memory_max_bytes{job=\"jvm\", area=\"heap\"}")
    gc = prom_instant("rate(jvm_gc_collection_seconds_sum{job=\"jvm\"}[2m])")
    threads = prom_instant("jvm_threads_current{job=\"jvm\"}")

    services = []
    for svc in prom_services:
        hp_used = heap_used.get(svc, 0)
        hp_max = heap_max.get(svc, 0)
        hp_pct = hp_used / hp_max if hp_max > 0 else 0
        c = cpu.get(svc, 0)
        g = gc.get(svc, 0)
        t = int(threads.get(svc, 0))

        status = "OK"
        issues = []
        if c >= 0.8: issues.append("CPU critical"); status = "CRITICAL"
        elif c >= 0.5: issues.append("CPU warning"); status = "WARNING"
        if hp_pct >= 0.85: issues.append("Heap critical"); status = "CRITICAL"
        elif hp_pct >= 0.7: issues.append("Heap warning"); status = max(status, "WARNING", key=lambda x: {"OK":0,"WARNING":1,"CRITICAL":2}[x])
        if g >= 0.1: issues.append("GC critical"); status = "CRITICAL"
        elif g >= 0.03: issues.append("GC warning"); status = max(status, "WARNING", key=lambda x: {"OK":0,"WARNING":1,"CRITICAL":2}[x])

        services.append({
            "service": svc,
            "pyroscope_name": SVC_MAP.get(svc, svc),
            "status": status,
            "cpu_rate": round(c, 3),
            "heap_used_mb": round(hp_used / 1024 / 1024, 1),
            "heap_max_mb": round(hp_max / 1024 / 1024, 1),
            "heap_pct": round(hp_pct, 3),
            "gc_rate": round(g, 4),
            "threads": t,
            "issues": issues,
        })

    order = {"CRITICAL": 0, "WARNING": 1, "OK": 2}
    services.sort(key=lambda s: (order.get(s["status"], 9), s["service"]))
    return services

# ---- SECTION: http ----

def collect_http():
    # Request rate by instance
    req_rate = prom_instant("sum by (instance) (rate(vertx_http_server_requests_total{job=\"vertx-apps\"}[2m]))")
    # Error rate by instance
    err_rate = prom_instant("sum by (instance) (rate(vertx_http_server_requests_total{job=\"vertx-apps\", code=~\"5..\"}[2m]))")
    # Avg latency by instance
    lat_sum = prom_instant("sum by (instance) (rate(vertx_http_server_response_time_seconds_sum{job=\"vertx-apps\"}[2m]))")
    lat_count = prom_instant("sum by (instance) (rate(vertx_http_server_response_time_seconds_count{job=\"vertx-apps\"}[2m]))")

    # Top slowest endpoints
    slow_results = prom_query(
        "topk(10, sum by (route) (rate(vertx_http_server_response_time_seconds_sum{job=\"vertx-apps\"}[5m])) "
        "/ sum by (route) (rate(vertx_http_server_response_time_seconds_count{job=\"vertx-apps\"}[5m])))"
    )
    slowest = []
    for r in slow_results:
        route = r["metric"].get("route", "unknown")
        val = float(r["value"][1])
        if val > 0:
            slowest.append({"route": route, "avg_latency_s": round(val, 4)})
    slowest.sort(key=lambda x: -x["avg_latency_s"])

    instances = sorted(set(list(req_rate.keys()) + list(lat_sum.keys())))
    if service_filter:
        container_name = REVERSE_MAP.get(service_filter, service_filter)
        instances = [i for i in instances if i.split(":")[0] == container_name]

    services = []
    for inst in instances:
        svc = inst.split(":")[0]
        rr = req_rate.get(inst, 0)
        er = err_rate.get(inst, 0)
        ls = lat_sum.get(inst, 0)
        lc = lat_count.get(inst, 0)
        avg_lat = ls / lc if lc > 0 else 0

        services.append({
            "instance": inst,
            "service": svc,
            "req_per_sec": round(rr, 2),
            "err_per_sec": round(er, 4),
            "err_pct": round(er / rr * 100, 2) if rr > 0 else 0,
            "avg_latency_ms": round(avg_lat * 1000, 1),
        })

    return {"services": services, "slowest_endpoints": slowest[:10]}

# ---- SECTION: profiles ----

def collect_profiles():
    CPU = "process_cpu:cpu:nanoseconds:cpu:nanoseconds"
    MEM = "memory:alloc_in_new_tlab_bytes:bytes:space:bytes"
    MUTEX = "mutex:contentions:count:mutex:count"

    services = []
    for svc in pyro_services:
        entry = {"service": svc}
        entry["cpu_top5"] = pyro_top_functions(svc, CPU, 5)
        entry["memory_top5"] = pyro_top_functions(svc, MEM, 5)
        entry["mutex_top5"] = pyro_top_functions(svc, MUTEX, 5)
        services.append(entry)

    return services

# ---- SECTION: alerts ----

def collect_alerts():
    if not prom_ok:
        return []
    try:
        url = f"{prometheus}/api/v1/alerts"
        resp = urllib.request.urlopen(url, timeout=10)
        data = json.loads(resp.read())
        alerts = data.get("data", {}).get("alerts", [])
        firing = [a for a in alerts if a.get("state") == "firing"]
        return [{
            "name": a.get("labels", {}).get("alertname", "unknown"),
            "severity": a.get("labels", {}).get("severity", "unknown"),
            "instance": a.get("labels", {}).get("instance", ""),
            "summary": a.get("annotations", {}).get("summary", ""),
            "active_since": a.get("activeAt", ""),
        } for a in firing]
    except Exception:
        return []

# ---- build report ----

sections = section.split(",") if "," in section else [section]

if "all" in sections or "health" in sections:
    report["health"] = collect_health()

if "all" in sections or "http" in sections:
    report["http"] = collect_http()

if "all" in sections or "profiles" in sections:
    report["profiles"] = collect_profiles()

if "all" in sections or "alerts" in sections:
    report["alerts"] = collect_alerts()

# ---- output ----

if json_mode:
    print(json.dumps(report, indent=2))
    sys.exit(0)

# Human-readable output
W = 76

print("")
print("=" * W)
print(f"  Diagnostic Report — {report['timestamp']}")
print("=" * W)
print(f"  Prometheus: {report['sources']['prometheus'] or 'UNREACHABLE'}")
print(f"  Pyroscope:  {report['sources']['pyroscope'] or 'UNREACHABLE'}")

if "health" in report:
    print("")
    print("-" * W)
    print("  JVM HEALTH")
    print("-" * W)
    for s in report["health"]:
        tag = {"OK": "  OK  ", "WARNING": " WARN ", "CRITICAL": " CRIT "}[s["status"]]
        print(f"  [{tag}] {s['service']}")
        print(f"           CPU: {s['cpu_rate']:.1%}   Heap: {s['heap_used_mb']:.0f}/{s['heap_max_mb']:.0f} MB ({s['heap_pct']:.1%})   GC: {s['gc_rate']:.4f} s/s   Threads: {s['threads']}")
        if s["issues"]:
            print(f"           Issues: {', '.join(s['issues'])}")

if "http" in report:
    http = report["http"]
    print("")
    print("-" * W)
    print("  HTTP TRAFFIC")
    print("-" * W)
    if http["services"]:
        print(f"  {'Service':<25} {'Req/s':>8} {'Err%':>7} {'Avg Lat':>10}")
        print(f"  {'-'*25} {'-'*8} {'-'*7} {'-'*10}")
        for s in http["services"]:
            print(f"  {s['service']:<25} {s['req_per_sec']:>8.1f} {s['err_pct']:>6.1f}% {s['avg_latency_ms']:>8.1f}ms")
    else:
        print("  (no HTTP traffic data)")

    if http["slowest_endpoints"]:
        print("")
        print("  Slowest endpoints (avg latency, last 5m):")
        for i, ep in enumerate(http["slowest_endpoints"][:5], 1):
            print(f"    {i}. {ep['avg_latency_s']*1000:>8.1f}ms  {ep['route']}")

if "profiles" in report:
    print("")
    print("-" * W)
    print("  PROFILING HOTSPOTS (last 1h)")
    print("-" * W)
    for s in report["profiles"]:
        print(f"")
        print(f"  {s['service']}")
        for label, key in [("CPU", "cpu_top5"), ("Memory", "memory_top5"), ("Mutex", "mutex_top5")]:
            funcs = s.get(key, [])
            if funcs:
                top = funcs[0]
                others = len(funcs) - 1
                print(f"    {label:8s}  {top['pct']:5.1f}%  {top['function']}" + (f"  (+{others} more)" if others else ""))
            else:
                print(f"    {label:8s}  (no data)")

if "alerts" in report:
    alerts = report["alerts"]
    print("")
    print("-" * W)
    print("  FIRING ALERTS")
    print("-" * W)
    if alerts:
        for a in alerts:
            print(f"  [{a['severity'].upper():>8}] {a['name']}  {a['instance']}")
            if a["summary"]:
                print(f"             {a['summary']}")
    else:
        print("  (none)")

print("")
print("=" * W)
print("  Quick follow-up commands:")
print("    bash scripts/diagnose.sh --json              # pipe to jq, scripts, etc.")
print("    bash scripts/diagnose.sh --section profiles  # just profiling data")
print("    bash scripts/top-functions.sh cpu             # detailed CPU hotspots")
print("    bash scripts/run.sh health                    # quick health check")
print("=" * W)
print("")
'

python3 -c "$DIAG_SCRIPT" \
  "$PROMETHEUS_URL" \
  "$PYROSCOPE_URL" \
  "$PROM_OK" \
  "$PYRO_OK" \
  "$JSON_MODE" \
  "$SECTION" \
  "$SERVICE_FILTER"
