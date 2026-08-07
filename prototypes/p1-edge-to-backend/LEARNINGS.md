# P1 — what happened, what we tried, and what we learned

Goal of P1: get telemetry flowing from an **OpenEMS Edge** to an **OpenEMS
Backend**, all local (no AWS/Odoo/hardware), and *prove* it's visible on the
backend side. Done — it took five fixes, each a useful lesson about OpenEMS.
We then added a **persistence layer** (InfluxDB) so history survives — two more
fixes (#6, #7 below). No Odoo/Postgres still; the only DB is the timeseries store.

## The build, step by step

1. **Stood up the stack from the official June release.** Two tiny Docker images
   that just download the prebuilt `openems-backend.jar` and `openems-edge.jar`
   (2026.6.0) and run them with `-Dfelix.cm.dir=config.d`. No source build. The
   edge got a minimal config: a simulated PV meter (`meter1`) driven by a
   datasource power profile, a reacting grid meter (`meter0`), the backend
   connector (`ctrlBackend0`), a scheduler, and a debug logger.

2. **Backend: ripped out Odoo + Postgres + RDS.** Replaced them with
   `Metadata.Dummy` (accepts any apikey, any login = admin) and `Timedata.Dummy`.
   That collapsed the original 6-service AWS compose down to **2 containers**.

Then it didn't work, and we debugged five distinct problems:

## The five things that went wrong (and the fix)

### 1. Backend never opened port 8081 → "the backend was split into two tiers"
The edge sat in an endless `NOT CONNECTED … reconnect` loop. The backend wasn't
listening on 8081 at all. Root cause: **in 2026.2.0, OpenEMS split the backend
into multiple servers** (officially: release notes 2026.2.0, *"Split services to
multiple servers — allows load-balancing Edge connections"*). The old monolithic
`Edge.Websocket` (one jar opens 8081) was replaced by `Edge.Manager` (a hub on
8083, *in* the published jar) + the `BackendEdge App` (`Backend.Edge.App`, the
edge-facing proxy that opens 8081). The gateway is **not shipped as a GitHub
release jar** — you build it (`./gradlew buildBackendEdgeApp`) or use the
`openems/backend-edge` Docker image. So the published 2026.6.0 backend jar
**cannot accept edges on its own.** OpenEMS even recommends pinning to 2026.1.0
for now (2026.2.0 notes, re: Odoo/KeyCloak auth changes).

→ Fix: use **2026.1.0**, the last monolithic backend. Keep the **edge on June
2026.6.0**. They interoperate (verified).
→ Implication for the cloud team: confirm what the real backend runs; a recent
release needs *both* tiers deployed (gateway built from source or via the
`openems/backend-edge` image).

### 2. Simulated meter wouldn't activate → "don't hand-write the datasource filter"
`meter1` silently never started. OpenEMS acting-meters auto-generate their
`datasource.target` OSGi filter *inside* `activate()` — but the reference is
`STATIC MANDATORY`, so it must bind *before* `activate()` runs. By setting the
filter myself I created a chicken-and-egg deadlock.
→ Fix: set only `datasource.id` and let OpenEMS write the filter.

### 3. Probe authenticated but got no data → "Metadata.Dummy has no per-edge role"
Built `probe_backend.py` to read telemetry back out of the backend's UI websocket
(:8082). Auth succeeded, subscribe returned success, but zero data. Backend log:
`Role was not defined for user=admin, edge=edge0`. `Metadata.Dummy` gives a
*global* admin role but no *per-edge* role, and the edgeRpc path checks per-edge.
→ Fix: call `getEdge` first — it side-effects `user.setRole(edge, ADMIN)`.

### 4. Still no data → "you must subscribeEdges before subscribeChannels"
Role fixed, still nothing. In the backend, `WsData.sendSubscribedChannels()`
returns early unless the edge is in the session's `subscribedEdges` set. The web
UI sends a `subscribeEdges` request to populate that; the probe wasn't.
→ Fix: send `subscribeEdges([edge0])` before `subscribeChannels`.

### 5. `subscribeEdges` got rate-limited → "pace the handshake"
First `subscribeEdges` attempt returned `4005 Too Many Requests`. The UI
websocket has a per-second request limiter, and a burst of back-to-back requests
on connect trips it.
→ Fix: ~0.4 s gaps between the auth/getEdge/subscribeEdges/subscribe steps.

After all five: the probe streams live PV values (800→4100 W) straight out of the
backend. Telemetry edge→backend→"cloud" confirmed.

## Adding the persistence layer (InfluxDB)

P1's backend ran `Timedata.Dummy` — live data worked but nothing was stored. To
make history durable we swapped in `Timedata.InfluxDB` + an InfluxDB v2 container.
The config contract came straight from OpenEMS source/docs (queryLanguage
`INFLUX_QL`, url/org/apiKey/bucket/measurement), so the values weren't the hard
part. Two non-obvious things were:

### 6. The factory config silently never loaded → "the file path *is* the PID"
Dropped `backend/config.d/Timedata/InfluxDB.config` with the right
`service.factoryPid`/`service.pid` inside. Backend booted clean, **no error**, but
the component sat at `no config` and nothing wrote to InfluxDB. ConfigAdmin's
status printer listed every other config but not this one.

Root cause: Felix's `FilePersistenceManager` (what `-Dfelix.cm.dir` uses) only
accepts a stored `.config` if the `service.pid` inside maps back to the file's
**path** (dots → directories) — `DictionaryEnumeration._seek()` quietly drops any
file that fails this check. My file's pid was `Timedata.InfluxDB.influx0`, which
maps to `Timedata/InfluxDB/influx0.config`, but I'd put it at
`Timedata/InfluxDB.config`. Mismatch → silently skipped.
→ Fix: move it to `Timedata/InfluxDB/influx0.config`. Component went `active`,
data flowed. This also corrects an earlier note in our own docs ("filenames don't
matter; the pid inside does") — the path is load-bearing. The edge's
`Controller/Api/Backend/ctrlBackend0.config` always worked precisely because its
path already equals its full instance pid.

How it was found: not by guessing. Walked the evidence — `components.json` showed
`no config`; ConfigAdmin's `status-Configurations.txt` confirmed the config was
never registered (so it was a *load* problem, not activation); every config that
*did* load had path == pid; then read the Felix 1.9.26 `FilePersistenceManager`
source, which spells out the path/pid consistency check.

### 7. Data is durable, but Dummy-metadata identity is not
After it worked, tested durability the honest way: stopped the edges (no new
data), `docker compose restart influxdb openems-backend`, queried history. The
**values survived** (InfluxDB on a named volume — direct query showed the
pre-restart numbers intact). But the *backend* history query by edge name was
denied: `Role was not defined for user=admin, edge=bronx-02`. InfluxDB tags each
series by a numeric edge id, and the name→number mapping lives in
`Metadata.Dummy`'s memory; a restarted backend with edges offline has forgotten
every edge, so `getEdge` grants no role and `edgeRpc` is rejected. Bring the edges
back (they re-register) and the same early buckets return the same values.
→ Lesson: with Dummy metadata, durability of *values* ≠ durability of *identity*.
Production (`Metadata.File`/`Metadata.Odoo`) persists the edge record, keeping
stored history attributable across restarts. This is the same per-edge-role
mechanism as #3, now seen from the persistence angle.

Verification artifact: `probe_history.py` (mirrors `probe_backend.py`, but issues
`queryHistoricTimeseriesData` instead of `subscribeChannels`).

## Durable learnings

- **OpenEMS is OSGi/Felix.** Everything is a component activated by a `.config`
  file (Felix format) found via `-Dfelix.cm.dir`. **The file's path is its PID**
  (dots → directories) and Felix silently ignores any `.config` whose internal
  `service.pid` doesn't match its path — so a factory instance must live at
  `<factoryPid-as-dirs>/<instance>.config` (e.g. `Timedata/InfluxDB/influx0.config`
  for pid `Timedata.InfluxDB.influx0`). "Component didn't activate" usually = file
  at the wrong path (→ never loaded, no error), wrong PID, unsatisfied
  `@Reference`, or `configurationPolicy = REQUIRE` with no config.
- **Persistence = `Timedata.InfluxDB` + an InfluxDB container.** Values are durable
  on a named volume; but `Metadata.Dummy` keeps the edge-name→numeric-id mapping in
  memory, so historic readback by edge name breaks across a backend restart until
  edges reconnect. Durable *values* ≠ durable *identity* — that needs persistent
  metadata.
- **Edge↔Backend is one persistent websocket** (`Controller.Api.Backend` →
  `:8081`), authenticated by `apikey`, carrying JSON-RPC. This *is* the link the
  HTTPS-vs-VPN spike is about — "make it HTTPS" = put TLS in front so it's `wss://`.
- **The backend is now a 2-tier system** (manager + edge gateway); only the
  manager is a published jar. This is the single most important deployment fact
  we learned.
- **Backend live data needs three things in order:** a per-edge role (`getEdge`),
  `subscribeEdges`, then `subscribeChannels`. Same dance the UI does.
- **Versions interoperate** across these releases for connect/config/data, so the
  edge can stay on June while the backend is pinned older — handy, but pin
  deliberately and write down why.
- **MQTT, looking ahead:** OpenEMS's native MQTT is mostly *publish*. Pulling a
  meter *in* over MQTT (P3) needs the community `io.openems.edge.meter.mqtt` or a
  custom component — that's the next real unknown to spike.

## Time/credit
All findings came from reading the OpenEMS source at the exact release tags and
from container logs — no guessing. The probe and configs are the artifacts.
