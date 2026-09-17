# P5-A — trying the newer two-tier OpenEMS backend (2026.6.0)

A spike to answer: **does the newer two-tier backend work with our stack** (the
one P1–P4 deliberately avoided by pinning the monolithic 2026.1.0)? A client
(Uganda team) reported it doesn't, with four fixes in pending PRs (#3795–#3798).
This prototype **reproduces their finding independently** on the stock release.

## Background: why we'd pinned 2026.1.0

From 2026.2.0 OpenEMS **split the backend's edge-facing tier out**: the old
in-jar `Edge.Websocket` became two pieces —
- **`Edge.Manager`** (in the backend jar; hub on **:8093**), and
- **`Backend.Edge.App`** — a separate **edge-facing gateway/aggregator** (image
  `openems/backend-edge`) that accepts edges on **:8081** and relays to the manager.

So the released backend jar can't accept edges alone; you must also run the
gateway. P1 pinned **2026.1.0** (monolithic) to avoid this. P5 revisits it.

## The stack (isolated from P1–P4: own network, `p5-` names, no port clash)

```
 sim edge ──ws :8081──►  openems-backend-edge  ──ws :8093──►  openems-backend      ──►  influxdb
 (p5edge-01)             (Backend.Edge.App,                    (Edge.Manager +
                          the aggregator)                       Metadata.File +
                                                                Timedata.InfluxDB)
```
Config is bind-mounted (`backend-config/`, `edge-config/`, `metadata.json`) — the
images seed defaults only if the config dir is empty, so our files win. We use
**Metadata.File + Timedata.InfluxDB** on purpose: the exact stack the client runs.

Run: `docker compose up -d` (pulls `openems/backend:2026.6.0` + `openems/backend-edge:2026.6.0`).

## The finding — stock two-tier can't serve a directly-connected edge

The tiers wire up fine (`Backend.Edge.Client [edges0] connected` to the manager).
But the edge never gets through:

| Metadata | `Backend.Edge.App` | `:8081` edge server | Edge result |
|---|---|---|---|
| **`Metadata.File`** (our/client's stack) | **active**, manager-connected | **never opens** | edge stuck `NOT CONNECTED`; **no data** |
| `Metadata.Dummy` (control) | active | opens | **`Handshake rejected. Invalid Apikey`**; no data |

- With **`Metadata.File`**, the aggregator's `:8081` server **silently never starts** — it has no crash, it just won't serve edges. It's missing the `apikey→edgeId` cache the aggregator needs. **→ PR #3797** (`Metadata.File.generateUpdateMetadataCacheNotification()`).
- Swapping *only* metadata to **`Dummy`** flips `:8081` on — proving the two-tier itself works and the gap is metadata-specific. But Dummy's cache is *empty* (no registered edges), so the aggregator rejects the edge's apikey. **→ the aggregator strictly requires a populated cache for directly-connected edges: PR #3796.**

Either way: **a directly-connected edge cannot reach the stock 2026.6/2026.7 two-tier backend with file-based metadata.** We never even got far enough to exercise #3795 (Controller.Api.Backend edge.manager notification wrapping) or #3798 (Influx resend/backfill) — the connection is blocked first, which matches their ordering.

## Conclusion

- **Independently validates the client's report** and PRs #3796/#3797 as the blockers.
- **Our pin to monolithic 2026.1.0 (P1–P4) remains the right call** until those land.
- The two-tier becomes viable either **after the August release** (PRs merged) or by
  **building from the client's PR branches** — that would be **P5-B**.

## Reproduce the key check

```bash
docker compose up -d
# tiers connect:
docker compose logs openems-backend | grep "Backend.Edge.Client \[edges0\] connected"
# but the aggregator never opens :8081 (Metadata.File):
docker exec p5-openems-backend-edge sh -c 'netstat -ltn | grep 8081' || echo ":8081 not listening"
# and the edge is stuck:
docker compose logs p5-sim-edge | grep -o 'ctrlBackend0\[[A-Za-z. ]*' | tail -1   # NOT CONNECTED
```

To stop: `docker compose down -v`.
