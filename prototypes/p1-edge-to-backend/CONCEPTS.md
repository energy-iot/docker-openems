# OpenEMS concepts: onboarding, config sync, and what the backend knows

How a new edge joins, and how the backend stays aware of every meter on it.
(All verified against OpenEMS 2026.6.0 source + observed in this prototype's logs.)

## 1. Onboarding = two layers

### a) Provisioning (ops / one-time)
For the backend to accept an edge, its **apikey must be known to the backend's
metadata service**:
- `Metadata.Dummy` (this prototype): accepts any apikey, auto-creates the edge.
- `Metadata.File` / `Metadata.Odoo` (production): the apikey is pre-registered —
  an edge record exists in the backend DB, assigned to a customer/community.
- There's also a **Setup Protocol** flow (`setupPassword`,
  `SubmitSetupProtocolRequest`) so an installer can *claim* an edge to a customer
  and record the install (serial numbers, who installed it, components).

So in real life: create the edge (apikey) in the backend, flash the Pi's edge
config with that `apikey` + `BACKEND_URI`, done.

### b) Connection handshake (automatic, every boot)
When the edge jar starts on the Pi (`io.openems.edge.controller.api.backend`):

```
1. Edge opens a websocket to BACKEND_URI, sending HTTP headers:
       Apikey: <apikey>          InstanceId: <uuid>
2. Backend authenticates the apikey via metadata -> resolves an Edge-ID (or rejects).
3. On open, the edge IMMEDIATELY:
     - sends its full EdgeConfig            (the complete component/channel model)
     - sends a one-time snapshot of ALL channel values
     - resends any buffered historic data   (data captured while it was offline)
4. Backend marks the edge online, records its version, stores the config.
5. Edge then streams `timestampedData` continuously.
```

We saw exactly this in the logs:
```
Edge [edge0]: Update version from [0.0.0] to [2026.6.0]      <- new edge, now known
Edge [edge0]. Update config: Created _sum, meter0, meter1, ctrlBackend0, ...
```
`[0.0.0]` = the backend had no prior record; the edge self-described on connect.

> ⚠️ Security: the apikey travels as an **HTTP header** in the handshake. The edge
> code itself warns that a non-`wss://` URI risks "credential exposure … do not use
> in production." This is precisely the HTTPS/VPN spike — `ws://` leaks the apikey.

## 2. Meters change → the protocol re-syncs automatically

**The backend is always aware of every component/meter on the edge.** It learns
them from the `EdgeConfig`, which per component carries:

| field | example |
|-------|---------|
| `id` | `meter1` |
| `factoryId` | `Simulator.ProductionMeter.Acting` (the component *type*) |
| `alias` | `Simulated PV` |
| `properties` | the component's config settings |
| `channels` | every channel + its **type, unit, access mode** |

When you **add, remove, or reconfigure a meter** on the edge, OpenEMS fires an
internal `TOPIC_CONFIG_UPDATE` event and the edge **re-sends the full EdgeConfig**
automatically. The backend diffs it against what it had and updates. No manual
step, no backend restart. We saw this live when `meter1` was added mid-run:
```
Edge [edge0]. Update config: Created meter1 (Simulator.ProductionMeter.Acting): ...
```

So, to answer the question directly:
- **Does the protocol handle meter changes, or do the values carry them?** → the
  **protocol** handles it, via the EdgeConfig sync (full snapshot on connect + a
  fresh snapshot on every change).
- **Do the telemetry values carry the structure?** → only partially. Each value is
  addressed `componentId/ChannelId` (e.g. `meter1/ActivePower`), so a value *names*
  its meter and channel — but the **meaning** (units, component type, the full
  channel list) comes from the EdgeConfig, not the value stream.
- **Is the backend aware of all meters linked to the edge?** → **Yes** — fully,
  including type, settings, and every channel, kept in sync as the edge changes.

## 3. Where readings are stored (Timedata)

The backend has a **pluggable Timedata layer**. The published backend jar ships:
| Component | Stores to | Notes |
|-----------|-----------|-------|
| `Timedata.Dummy` | nowhere | discards data (live only, no history) — P1's original setup |
| `Timedata.InfluxDB` | InfluxDB | the common production TSDB — **what P1 uses now** |
| `Timedata.TimescaleDB` | PostgreSQL/TimescaleDB | relational hypertable option |
| `Timedata.AggregatedInfluxDB` | InfluxDB | pre-aggregated variant |

**InfluxDB schema** (from source): one measurement **`data`**, a single tag **`edge`**
= the **numeric** edge id (`parseNumberFromName`: `edge0`→0, `bronx-01`→1), and one
**field per channel** (`_sum/GridActivePower`, `meter1/ActivePower`, …) → value,
timestamped. So it's a wide, tag-partitioned series:
```
measurement=data, tag edge=1, fields {_sum/GridActivePower:-7000, meter1/ActivePower:7000, ...}, time=...
```
> ⚠️ The `edge` tag is a **number** pulled from the id — so edge ids need
> **globally-unique trailing numbers** (that's why cluster mode numbers globally:
> bronx-01, bronx-02, queens-03, queens-04). Duplicate numbers collide in storage.

### Is one edge isolated?
- **Connection/identity:** yes — separate websocket, apikey, and config per edge;
  edges never see each other.
- **Access control:** users have **per-edge roles** — you only see edges you're
  authorized for (multi-tenant).
- **Storage:** logically isolated by the `edge` tag in a **shared** bucket/measurement
  (not a DB-per-edge by default; you *could* shard buckets). Queries filter by tag.

### Connecting directly
- **To the TSDB:** yes — InfluxDB exposes its API/UI on :8086; query with Flux/
  InfluxQL, or point Grafana at it.
- **To an edge (bypassing the cloud):** yes — each edge can expose its OWN local
  APIs: `Controller.Api.Rest` (REST/JSON), `Controller.Api.Websocket` (local UI),
  `Controller.Api.ModbusTcp`. So on the Pi you can read/write the edge locally
  (curl the REST API, Modbus poll) without the backend; the OpenEMS UI can also
  connect straight to an edge ("edge mode").

> P1 status: **persistence is live** — `Timedata.InfluxDB` writes to an InfluxDB
> container, and `probe_history.py` reads it back out through the backend. The
> standalone release jar *does* activate the influx writer (an earlier guess that
> it didn't was wrong); the only catch was the config file's path — it must equal
> the component's pid (`Timedata/InfluxDB/influx0.config`), or Felix silently skips
> it. See README "Persistence layer" and LEARNINGS #6.

## 4. Why this matters for the fleet

- Swapping the ESP32/SunSpec meter, or adding a second meter, needs **no backend
  change** — the edge re-announces itself.
- The backend's stored EdgeConfig is what powers the UI (it knows what widgets to
  show), historic data schema, and alerting — all driven by what each edge reports
  about itself.
- Production needs **real metadata** (`Metadata.File`/`Odoo`) so apikeys are
  provisioned per community, plus **`wss://`** so the apikey isn't sent in clear.
