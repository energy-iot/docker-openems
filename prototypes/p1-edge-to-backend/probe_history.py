#!/usr/bin/env python3
"""
P1 *persistence* probe (multi-edge).

Companion to probe_backend.py. Where that probe proves *live* telemetry is
visible out of the backend, this one proves *history* is: it asks the backend
for stored time-series data via the same JSON-RPC the web UI's history view
uses (`queryHistoricTimeseriesData`). Every value returned was produced on an
edge, pushed to the backend, written to InfluxDB by Timedata.InfluxDB, and read
back out -- i.e. telemetry that *persisted*, not just streamed past.

If you see rows here after a `docker compose restart openems-backend` (or even
after the data stopped being produced), persistence works.

Usage:
  python3 probe_history.py                 # edge0..edge4, today (UTC)
  python3 probe_history.py bronx-01,queens-03
  python3 probe_history.py 3 2026-06-29    # edge0..edge2, explicit date
Requires: pip install websocket-client
"""
import json
import sys
import time
import uuid
from datetime import datetime, timezone
from websocket import create_connection

URL = "ws://localhost:8082"

arg = sys.argv[1] if len(sys.argv) > 1 else "5"
if arg.isdigit():
    EDGES = [f"edge{i}" for i in range(int(arg))]
else:
    EDGES = [e.strip() for e in arg.split(",") if e.strip()]
# The backend stores InfluxDB timestamps in UTC; query the UTC day so freshly
# written data (which may be "tomorrow" in UTC just after midnight) is covered.
DAY = sys.argv[2] if len(sys.argv) > 2 else datetime.now(timezone.utc).strftime("%Y-%m-%d")

CHANNELS = [
    "_sum/ProductionActivePower",
    "_sum/ConsumptionActivePower",
    "_sum/GridActivePower",
]


def rpc(method, params):
    return json.dumps({"jsonrpc": "2.0", "id": str(uuid.uuid4()),
                       "method": method, "params": params})


def find_key(obj, key):
    """Depth-first search for the first dict that contains `key`."""
    if isinstance(obj, dict):
        if key in obj:
            return obj
        for v in obj.values():
            r = find_key(v, key)
            if r is not None:
                return r
    elif isinstance(obj, list):
        for v in obj:
            r = find_key(v, key)
            if r is not None:
                return r
    return None


def query_history(ws, edge):
    inner = {"jsonrpc": "2.0", "id": str(uuid.uuid4()),
             "method": "queryHistoricTimeseriesData",
             "params": {
                 "timezone": "UTC",
                 "fromDate": DAY,
                 "toDate": DAY,
                 "channels": CHANNELS,
                 "resolution": {"value": 1, "unit": "MINUTES"},
             }}
    ws.send(rpc("edgeRpc", {"edgeId": edge, "payload": inner}))
    # Read until we get a response carrying timestamps/data (skip notifications).
    ws.settimeout(8.0)
    for _ in range(20):
        try:
            msg = json.loads(ws.recv())
        except Exception:
            break
        hit = find_key(msg, "timestamps")
        if hit is not None and "data" in hit:
            return hit
    return None


def summarize(edge, res):
    if res is None:
        print(f"  {edge:<11} no response")
        return 0
    ts = res.get("timestamps") or []
    data = res.get("data") or {}
    prod = data.get("_sum/ProductionActivePower") or []
    non_null = [v for v in prod if v is not None]
    if not ts or not non_null:
        print(f"  {edge:<11} {len(ts):>4} buckets, but no Production values")
        return 0
    print(f"  {edge:<11} {len(ts):>4} buckets  "
          f"Production first={non_null[0]!s:>7}  last={non_null[-1]!s:>7} W  "
          f"({ts[0]} .. {ts[-1]})")
    return len(non_null)


def main():
    print(f"connecting to backend {URL} ...")
    ws = create_connection(URL, timeout=10)
    ws.send(rpc("authenticateWithPassword",
                {"username": "admin", "password": "admin"}))
    if "error" in json.loads(ws.recv()):
        print("AUTH FAILED"); sys.exit(1)
    print(f"authenticated; querying stored history for {DAY} (UTC), "
          f"{len(EDGES)} edge(s)\n")

    # Per-edge role grant -- edgeRpc checks a per-edge role (see LEARNINGS.md #3).
    for e in EDGES:
        time.sleep(0.3)
        ws.send(rpc("getEdge", {"edgeId": e})); ws.recv()

    print(f"{'':2}{'edge':<11}stored history")
    total = 0
    for e in EDGES:
        time.sleep(0.3)
        total += summarize(e, query_history(ws, e))

    ws.close()
    print("-" * 60)
    if total:
        print(f"OK: read {total} persisted Production samples back out of the "
              f"backend. Telemetry is durable (InfluxDB).")
    else:
        print("NO stored history returned. Is Timedata.InfluxDB active and has "
              "data been flowing for a minute? (see README persistence section)")
        sys.exit(2)


if __name__ == "__main__":
    main()
