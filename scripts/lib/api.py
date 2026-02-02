#!/usr/bin/env python3
"""Shared API clients for Prometheus and Pyroscope.

Provides consistent error handling, timeouts, and logging for all HTTP
interactions with the monitoring stack. Used by diagnose.py, jvm_health.py,
and parse_flamegraph.py.

All functions return empty results on failure rather than raising, since
partial data is better than crashing a diagnostic report.
"""
import json
import logging
import sys
import urllib.error
import urllib.parse
import urllib.request

logger = logging.getLogger(__name__)

DEFAULT_TIMEOUT = 10  # seconds

# --- Service name mapping ---
# Container name -> Pyroscope application name

SVC_MAP = {
    "api-gateway": "bank-api-gateway",
    "order-service": "bank-order-service",
    "payment-service": "bank-payment-service",
    "fraud-service": "bank-fraud-service",
    "account-service": "bank-account-service",
    "loan-service": "bank-loan-service",
    "notification-service": "bank-notification-service",
    "stream-service": "bank-stream-service",
}

REVERSE_MAP = {v: k for k, v in SVC_MAP.items()}


# --- HTTP helper ---

def _fetch_json(url, method="GET", body=None, headers=None, timeout=DEFAULT_TIMEOUT):
    """Fetch JSON from a URL. Returns parsed dict or None on any error."""
    # Only allow http/https schemes to prevent file:// or ftp:// access (B310)
    if not url.startswith(("http://", "https://")):
        logger.warning("Refusing non-HTTP URL: %s", url)
        return None
    try:
        req = urllib.request.Request(url, method=method)
        if headers:
            for k, v in headers.items():
                req.add_header(k, v)
        data = body.encode() if isinstance(body, str) else body
        resp = urllib.request.urlopen(req, data=data, timeout=timeout)  # nosec B310 - scheme validated above
        return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        logger.warning("HTTP %d from %s", e.code, url)
        return None
    except urllib.error.URLError as e:
        logger.warning("Connection failed for %s: %s", url, e.reason)
        return None
    except (json.JSONDecodeError, OSError) as e:
        logger.warning("Failed to parse response from %s: %s", url, e)
        return None


# --- Prometheus client ---

def prom_query(base_url, expr):
    """Run an instant PromQL query. Returns list of {metric, value} results."""
    url = "{}/api/v1/query?query={}".format(base_url, urllib.parse.quote(expr))
    data = _fetch_json(url)
    if data is None:
        return []
    return data.get("data", {}).get("result", [])


def prom_instant(base_url, expr):
    """Run a PromQL query and return {instance_name: float_value}.

    Instance is normalized to the container name (before the first colon).
    """
    out = {}
    for r in prom_query(base_url, expr):
        inst = r["metric"].get("instance", "unknown").split(":")[0]
        try:
            out[inst] = float(r["value"][1])
        except (IndexError, ValueError, TypeError):
            logger.warning("Bad value in Prometheus result for %s", inst)
    return out


def prom_alerts(base_url):
    """Fetch currently firing alerts from Prometheus."""
    data = _fetch_json("{}/api/v1/alerts".format(base_url))
    if data is None:
        return []
    alerts = data.get("data", {}).get("alerts", [])
    return [a for a in alerts if a.get("state") == "firing"]


# --- Pyroscope client ---

def pyro_label_values(base_url, label="service_name"):
    """Fetch label values from Pyroscope."""
    data = _fetch_json(
        "{}/querier.v1.QuerierService/LabelValues".format(base_url),
        method="POST",
        body=json.dumps({"name": label}),
        headers={"Content-Type": "application/json"},
    )
    if data is None:
        return []
    return data.get("names", [])


def pyro_render(base_url, profile_id, service, time_range="1h"):
    """Fetch a flamegraph render from Pyroscope. Returns raw JSON dict or None."""
    query = '{}{{service_name="{}"}}'.format(profile_id, service)
    url = "{}/pyroscope/render?query={}&from=now-{}&until=now&format=json".format(
        base_url, urllib.parse.quote(query), time_range)
    return _fetch_json(url)


def pyro_top_functions(base_url, service, profile_id, n=5):
    """Return top N functions by self-time for a service/profile.

    Returns list of {"function": str, "self": int, "pct": float}.
    """
    data = pyro_render(base_url, profile_id, service)
    if data is None:
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
    return [{"function": name, "self": val, "pct": round(val / total * 100, 1)}
            for name, val in top]
