# P1 — OpenEMS Edge → Backend, local loop

The first prototype for [energy-iot/docker-openems#79](https://github.com/energy-iot/docker-openems/issues/79):
prove that telemetry flows **from an OpenEMS Edge to an OpenEMS Backend and is
visible "in the cloud"**, with everything running locally on a laptop — no AWS,
no Odoo, no Postgres, no physical meter.

```
            docker compose (one host)                       one shared backend
 ┌───────────────────────────┐                            ┌────────────────────────┐         ┌──────────────┐
 │ edge0  (PV x1)             │──┐                         │ openems-backend         │         │  influxdb     │
 │ edge1  (PV x2)             │  │   ctrlBackend0          │ (2026.1.0, monolithic)  │  writes │  (v2, :8086)  │
 │ edge2  (PV x3)             │  ├──► ws://…:8081  ──────► │  • Edge.Websocket :8081 │ ──────► │  bucket       │
 │ edge3  (PV x4)             │  │   apikey = edgeN        │  • Ui.Websocket   :8082 │ ◄────── │  "openems"    │
 │ edge4  (PV x5)             │──┘                         │  • Metadata.Dummy       │  reads  │  (named vol)  │
 │  each: ProductionMeter +   │                            │  • Timedata.InfluxDB    │         └──────────────┘
 │  GridMeter + Backend conn  │                            └───────────┬────────────┘
 └───────────────────────────┘                                        │  ws :8082
        N configurable edges        probe_backend.py  ────────────────┤  live data, like the UI
                                     probe_history.py  ────────────────┘  stored history, like the UI
```

Each edge is one container = one "community site". It runs a **simulated PV
meter** (a power profile, scaled per-site) plus a reacting grid meter, and pushes
telemetry to the shared backend. No hardware needed; later prototypes swap the
simulator for an MQTT-fed meter and then the real device — by changing config only.

## Run it

```bash
# flat: 5 anonymous edges
./scale-edges.sh 5
# OR clusters: named communities (recommended — you can tell sites apart)
./scale-edges.sh bronx=3 queens=2     # -> bronx-01..03, queens-01..02

docker compose up -d --build          # first run downloads jars (~a minute)
docker compose ps                     # backend + edges
python3 probe_backend.py bronx-01,bronx-02,...   # the command is printed by scale-edges
```

`scale-edges.sh` rewrites `docker-compose.override.yml`; re-run with any
spec and `docker compose up -d` again. Each edge needs ~30–60 s to connect on
first boot (it starts before the backend socket is open and retries). That's
expected — you'll briefly see `Unable to send … Connection is closed` while it
buffers, then it connects.

### Configuring an edge

Each edge is driven by env vars (see `edge/entrypoint.sh`), so the image is
generic and a site is pure configuration:

| Env | Default | Meaning |
|-----|---------|---------|
| `EDGE_ID` | `edge0` | the apikey/identity the backend files this edge under. **Must end in digits** (e.g. `bronx-02`) so the backend keeps the readable name; the number also scales the simulated PV |
| `CLUSTER` | _(none)_ | human label for the site/community → written into OpenEMS `Core.Meta.placeName` and shown by the probe |
| `LAT` / `LON` | _(none)_ | optional decimal coordinates → `Core.Meta` (the backend can map sites) |
| `BACKEND_URI` | `ws://openems-backend:8081` | where to push telemetry (point at a real cloud backend here) |
| `EDGE_DEBUG` | `false` | log extra detail |

So "which cluster is this data from?" is answered two ways at once: the **edge-id
prefix** (`bronx-…`), visible in every log/telemetry line, and the **`Core.Meta`
placeName**, stored as proper OpenEMS edge metadata.

## Web UI

Open **http://localhost:8080** and log in with **`admin` / `admin`** (any
credentials work — `Metadata.Dummy` treats every login as admin). You'll see the
online edges; click one for its live energy view, **Settings → Components** for
its meters.

- **Language:** the UI defaults to **German** because `Metadata.Dummy` hardcodes
  the user language to `DE`. Switch it in the UI: top-right menu → **Account /
  Settings → Language → English** (persists in the browser). There's no config
  knob for this under Dummy metadata.
- **"Server not accessible"?** That's the UI's websocket to the backend being
  down. If you just recreated the backend, the custom nginx template
  (`ui/80-openems.conf.tpl`, with a `resolver`) makes nginx re-resolve within
  ~10s. If it persists, check the backend is up (`docker compose ps`).

## How to test / verify

Three independent checks, weakest→strongest proof:

**1. Edges are producing telemetry and connected** — watch one edge's log:
```bash
docker compose logs --tail 3 openems-edge0
# _sum[State:Ok Grid:-3200 W Production:3200 W ...] ctrlBackend0[Connected] meter1[3200 W]
```
`ctrlBackend0[Connected]` = the edge→backend websocket is up. `meter1` = the PV.

**2. Backend registered all edges** — watch the backend log:
```bash
docker compose logs openems-backend | grep -E "Edge \[edge[0-9]\]: Update version"
# Edge [edge0]: Update version from [0.0.0] to [2026.6.0]   ... (one per edge)
```
This proves each edge authenticated and the backend has its component model.

**3. Telemetry is visible *out of the backend* (the real acceptance test)** —
read live values for every edge back through the backend's UI websocket, exactly
like the OpenEMS web UI would:
```bash
python3 probe_backend.py 5          # needs: pip install websocket-client
# [hh:mm:ss]  edge   Production  Consumption    Grid  State
#             edge0     2000 W        0 W   -2000 W      0
#             edge2     6000 W        0 W   -6000 W      0
#             edge4    10000 W        0 W  -10000 W      0
# OK: received live data from 5/5 edges.
```
Every number originated on an edge, crossed the network to the backend, and was
served back out — i.e. it's "in the cloud."

**4. History persisted and is queryable (the persistence acceptance test)** —
the backend now runs `Timedata.InfluxDB` (not `Timedata.Dummy`), so telemetry is
written to InfluxDB and survives restarts. Read it back out the same way the UI's
history view does (`queryHistoricTimeseriesData`):
```bash
python3 probe_history.py bronx-01,bronx-02,queens-03,queens-04
#   edge       stored history
#   bronx-01    1440 buckets  Production first=4492.3  last=5600 W  (..00:00Z .. 23:59Z)
#   ...
# OK: read 20 persisted Production samples back out of the backend.
```
Stronger proof of durability: stop the edges (no new data), `docker compose
restart influxdb openems-backend`, bring the edges back, and re-run — the early
buckets return the **same** values as before the restart (the data was on disk,
not in memory). You can also look directly in the store:
```bash
docker exec openems-influxdb influx query --org openems.io \
  --token openems-p1-dev-token \
  'from(bucket:"openems") |> range(start:-1h) |> filter(fn:(r)=>r._field=="_sum/ProductionActivePower") |> last()'
```

## Persistence layer (InfluxDB)

An `influxdb` container (InfluxDB v2) holds the history. It **auto-bootstraps**
from `DOCKER_INFLUXDB_INIT_*` env on first boot — org `openems.io`, bucket
`openems`, and a *pinned* admin token — so the whole stack still comes up from a
single `docker compose up`, no manual `influx setup`/token-copying. The backend's
`backend/config.d/Timedata/InfluxDB/influx0.config` points at it with that token
and `queryLanguage=INFLUX_QL` (the combination OpenEMS's own docs prescribe).

The token (`openems-p1-dev-token`) and password are **throwaway dev credentials**
baked into config — fine for a local prototype, rotate for anything real. Stored
data lives in the named volume `influxdb-data` and survives `docker compose down`;
to wipe history, `docker compose down -v` (or `docker volume rm
p1-edge-to-backend_influxdb-data`).

> ⚠️ **Durability has two halves, and Dummy metadata only does one.** The *values*
> are durable (InfluxDB, on disk). But InfluxDB tags each series by a *numeric*
> edge id, and the edge-name→number mapping lives in **`Metadata.Dummy`'s memory**.
> Restart the backend with the edges offline and that mapping is gone, so a
> history query by edge name is denied (`Role was not defined … edge=bronx-02`)
> and returns nothing until the edges reconnect and re-register. Production
> metadata (`Metadata.File`/`Metadata.Odoo`) persists the edge record, so stored
> history stays attributable across restarts. See LEARNINGS.

To stop: `docker compose down` (keeps history); `docker compose down -v` (wipes it).

## What flows from each edge

The edge→backend link is **one persistent websocket carrying JSON-RPC**. Three
kinds of traffic go up it:

1. **On connect — identity + model.** The edge authenticates with its `apikey`,
   sends its version, and pushes its full component config (`Edge [edgeN]: Update
   config: Created _sum, meter0, meter1, ctrlBackend0 ...`). This is how the
   backend knows what the site *is*.
2. **Continuously — channel telemetry** as `timestampedData` notifications:
   `{ "<unix-ms>": { "<component>/<Channel>": value, ... } }` for every channel
   marked persistent. A real snapshot from `edge2` (the ×3 PV site):
   ```
   _sum/ProductionActivePower    = 7200      # total PV right now (W)
   _sum/ConsumptionActivePower   = 0         # site load (W)
   _sum/GridActivePower          = -7200     # negative = exporting to grid (W)
   _sum/State                    = 0         # 0=OK,1=INFO,2=WARN,3=FAULT
   meter1/ActivePower            = 7200      # the PV meter
   meter1/ActiveProductionEnergy = 257       # lifetime energy counter (Wh)
   meter0/ActivePower            = -7200     # grid meter
   meter0/VoltageL1              = 230000     # phase voltage (mV) -> 230.0 V
   ```
   Channels the simulator doesn't drive (`EssSoc`, `Frequency`, per-phase current)
   report `null` — on a real device those carry battery SoC, grid frequency, etc.
3. **Backend → edge (same socket, reverse).** The backend can subscribe to live
   channels (what the probe triggers) and, in a control scenario, *write*
   setpoints back (e.g. limit export, set a relay). The edge→cloud direction is
   pure reads; that reverse control path is the part the HTTPS-vs-VPN spike cares
   about.

### Are the channels fixed? (Yes — they're a standard schema called "Natures")

The channel *names* are **not** arbitrary per device. OpenEMS defines standard
interfaces called **Natures**, and every component implements the relevant one,
so all devices of a kind expose the **same** channels regardless of brand or
protocol. The meter Nature (`ElectricityMeter`) is:

```
ActivePower  ReactivePower  Voltage  Current  Frequency
ActiveProductionEnergy  ActiveConsumptionEnergy
(+ per-phase: ActivePowerL1/L2/L3, VoltageL1/L2/L3, CurrentL1/L2/L3)
```

A battery implements `SymmetricEss` (`Soc`, `ActivePower`, `Capacity`, …); the
site aggregate `_sum` always exposes `ProductionActivePower`,
`ConsumptionActivePower`, `GridActivePower`, `EssSoc`, `State`, etc.

So **yes, every edge device "converts" its raw data into these channels** — that's
a device driver's whole job: map protocol-specific registers/fields onto the
Nature. A Modbus meter maps register `0x2000 → ActivePower`; the **MQTT meter in
P3 will map a JSON field in the `OpenAMI` topic → ActivePower**; the SunSpec
device in your photo maps model 701/713 fields the same way. Downstream
(backend, UI, controllers) only ever sees the normalized channels, so it doesn't
care what the device is. Components may add *extra* vendor-specific channels on
top, but the Nature is the common contract.

Which channels a given edge emits = which components it's configured with (`_sum`
always; `meterN`/`essN` per device). Swap the simulator for a real meter and the
same channel shapes flow — just real values.

## Why these versions (important finding)

- **Edge = 2026.6.0** (June release — the version the ticket asks for; carries
  the merged Chint DDSU666 edge-meter patch, irrelevant to this sim but keeps us
  on the right line).
- **Backend = 2026.1.0** on purpose. This is **officially documented**, not a
  guess:
  - **In 2026.2.0 the OpenEMS backend was split into multiple servers.** Release
    notes for 2026.2.0: *"Backend improvements: Split services to multiple servers
    — allows load-balancing Edge connections."* (Confirmed in source: the main
    `BackendApp.bndrun` contains `edgewebsocket` in 2026.1.0 but `edge.manager`
    from 2026.2.0 on.)
  - **OpenEMS itself recommends pinning to 2026.1.0** right now. Same 2026.2.0
    notes: *"large changes to the OpenEMS Backend authentication flow to Odoo and
    KeyCloak … not yet included in the Odoo-Addon and the Docker-Compose setups.
    For now it is recommended to use older OpenEMS Backend (namely 2026.1.0)."*
  - The new edge-facing tier is **`io.openems.backend.edge.application`**
    ("BackendEdge App") — its own README describes it as *"a proxy application
    that acts as an intermediary between OpenEMS Edge instances and the OpenEMS
    Backend … runs on an independent server."* It accepts edges on **8081** and
    relays to the **Edge-Manager** on **8083**. It is **not a GitHub release jar**
    — you build it with `./gradlew buildBackendEdgeApp` (→ `openems-backend-edge.jar`),
    or run the official Docker image `openems/backend-edge`.
  - **2026.1.0 is the last monolithic backend** (single jar, `Edge.Websocket` on
    8081). Edge↔backend JSON-RPC is stable across these months, so the June edge
    talks to the 2026.1.0 backend fine (verified here).

  → For the **real cloud deployment** (Aaron's `openems.nearlyfreeenergy.com:8081`)
  this is the key decision: either (a) pin the backend to **2026.1.0** as OpenEMS
  advises, or (b) run the newer **2-tier** topology (`openems/backend` +
  `openems/backend-edge` Docker images, or build the gateway jar). Worth confirming
  which the test backend already uses.

## Config notes (gotchas worth knowing)

- **No Odoo/DB for *metadata*.** `Metadata.Dummy` accepts any apikey
  (auto-provisions `edge0..edge10`) and treats any UI login as admin. History,
  though, *is* now persisted: `Timedata.InfluxDB` → an InfluxDB container (see the
  Persistence section). Originally this was `Timedata.Dummy`, which discarded
  history while live data still worked.
- **`Metadata.Dummy` has no per-edge roles.** The probe must call `getEdge`
  (side-effect: grants the session an ADMIN role for the edge) and `subscribeEdges`
  (without it the backend never pushes channel data) *before* `subscribeChannels`.
- **Simulator meter reference:** the acting meter's `datasource.target` filter is
  auto-generated by OpenEMS inside `activate()`. Do **not** hand-write it — a
  static mandatory reference must bind first, so setting it yourself deadlocks
  activation. Set only `datasource.id`.
- Config is the Apache Felix `.config` format under each container's `config.d/`,
  loaded via `-Dfelix.cm.dir`. **The file's path *is* its PID** — Felix only loads
  a `.config` if its `service.pid` maps back to the path (dots → directories). So
  the folder layout is **not** cosmetic: `Metadata/Dummy.config` ⇒ pid
  `Metadata.Dummy`. (Earlier notes here said "filenames don't matter" — that was
  wrong, and cost real time; see LEARNINGS.)
- **Factory configs need the instance in the path too.** A factory component
  (e.g. `Timedata.InfluxDB`, `factory=true`) needs a file whose path equals the
  full instance pid `<factoryPid>.<instance>`. Hence
  `Timedata/InfluxDB/influx0.config` (pid `Timedata.InfluxDB.influx0`,
  factoryPid `Timedata.InfluxDB`) — **not** `Timedata/InfluxDB.config`, which
  Felix silently ignores for a factory. Same rule the edge follows for
  `Controller/Api/Backend/ctrlBackend0.config`.

## What's next (per the ticket ramp)

- **P2** — run this edge on the 2 GB Pi (SL-RP4) with a slimmed bundle; point it
  at this backend on the laptop.
- **P3** — Mosquitto broker + a dummy meter publishing to topic `OpenAMI`; edge
  ingests it as a channel (swap the simulator for the MQTT meter).
- **P4** — secure the edge→backend hop (wss/TLS + apikey; optionally OpenVPN).
