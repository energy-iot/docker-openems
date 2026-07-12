#!/usr/bin/env python3
"""
P1 verification probe (multi-edge).

Connects to the OpenEMS *Backend* UI-websocket (the endpoint the web UI uses),
authenticates, and subscribes to live channels of one or more edges. Every value
printed originated on an edge, was pushed over the edge->backend websocket, and
is read back out of the backend -- i.e. telemetry visible "in the cloud".

Usage:
  python3 probe_backend.py            # default: edge0..edge4 (5 edges), 12s
  python3 probe_backend.py 3          # edge0..edge2
  python3 probe_backend.py edge0,edge2 20
Requires: pip install websocket-client
"""
import json
import sys
import time
import uuid
from websocket import create_connection

URL = "ws://localhost:8082"

# --- parse args: a count -> edge0..edge(N-1), or an explicit comma list -------
arg = sys.argv[1] if len(sys.argv) > 1 else "5"
if arg.isdigit():
    EDGES = [f"edge{i}" for i in range(int(arg))]
else:
    EDGES = [e.strip() for e in arg.split(",") if e.strip()]
DURATION = float(sys.argv[2]) if len(sys.argv) > 2 else 12.0

CHANNELS = [
    "_sum/ProductionActivePower",
    "_sum/ConsumptionActivePower",
    "_sum/GridActivePower",
    "_sum/State",
]


def rpc(method, params):
    return json.dumps({"jsonrpc": "2.0", "id": str(uuid.uuid4()),
                       "method": method, "params": params})


def main():
    print(f"connecting to backend {URL} ...")
    ws = create_connection(URL, timeout=10)

    ws.send(rpc("authenticateWithPassword",
                {"username": "admin", "password": "admin"}))
    auth = json.loads(ws.recv())
    if "error" in auth:
        print("AUTH FAILED:", auth["error"]); sys.exit(1)
    print(f"authenticated; watching {len(EDGES)} edge(s): {', '.join(EDGES)}\n")

    # Per-edge role grant (getEdge side-effects user.setRole(edge, ADMIN)).
    for e in EDGES:
        time.sleep(0.3)
        ws.send(rpc("getEdge", {"edgeId": e})); ws.recv()

    # subscribeEdges enables the backend to push data for these edges at all.
    time.sleep(0.3)
    ws.send(rpc("subscribeEdges", {"edges": EDGES})); ws.recv()

    # Subscribe to channels per edge (edgeRpc wraps an inner subscribeChannels).
    for e in EDGES:
        time.sleep(0.3)
        inner = {"jsonrpc": "2.0", "id": str(uuid.uuid4()),
                 "method": "subscribeChannels",
                 "params": {"count": 1, "channels": CHANNELS}}
        ws.send(rpc("edgeRpc", {"edgeId": e, "payload": inner})); ws.recv()

    latest = {}          # edgeId -> dict of channel values
    ws.settimeout(2.0)
    deadline = time.time() + DURATION
    next_print = time.time() + 2.0
    updates = 0

    while time.time() < deadline:
        try:
            msg = json.loads(ws.recv())
        except Exception:
            msg = None
        if msg and msg.get("method") == "edgeRpc":
            p = msg.get("params", {})
            payload = p.get("payload", {})
            if payload.get("method") == "currentData":
                latest[p.get("edgeId")] = payload.get("params", {})
                updates += 1
        if time.time() >= next_print:
            print_snapshot(latest)
            next_print += 2.0

    ws.close()
    print("-" * 60)
    got = [e for e in EDGES if e in latest]
    if got:
        print(f"OK: received live data from {len(got)}/{len(EDGES)} edges "
              f"({updates} updates total).")
    else:
        print("NO live updates. Are the edges connected? "
              "(docker compose ps / logs)")
        sys.exit(2)


def cluster_of(edge_id):
    # "bronx-02" -> "bronx"; "edge3" -> "-"
    return edge_id.rsplit("-", 1)[0] if "-" in edge_id else "-"


def print_snapshot(latest):
    ts = time.strftime("%H:%M:%S")
    print(f"[{ts}]  {'cluster':<10}{'edge':<11}{'Production':>12}{'Consumption':>13}{'Grid':>10}{'State':>7}")
    for e in sorted(latest):
        d = latest[e]
        def g(k):
            v = d.get(k)
            return "-" if v is None else v
        print(f"{'':9}{cluster_of(e):<10}{e:<11}"
              f"{str(g('_sum/ProductionActivePower'))+' W':>12}"
              f"{str(g('_sum/ConsumptionActivePower'))+' W':>13}"
              f"{str(g('_sum/GridActivePower'))+' W':>10}"
              f"{str(g('_sum/State')):>7}")
    print()


if __name__ == "__main__":
    main()
