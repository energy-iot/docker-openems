# P2 — OpenEMS edge on the SL-RP4 Pi, with real onboarding (PLAN)

Status: **DONE & verified on hardware** (slrp4-09 on the SL-RP4, coexisting with
OpenPLC). See README.md (how to use) and LEARNINGS.md (what we hit). This doc is
the original agreed plan, kept for the record.

## Goal

A **repeatable way to turn a Pi into a registered OpenEMS edge** that runs as a
memory-capped service *alongside* OpenPLC and pushes telemetry to the backend on
the laptop. Two-step onboarding, mirroring how OpenEMS does it for real:

```
  (laptop)                                   (Pi)
  register-edge.sh bronx-05  ──►  apikey + ready-to-run command
                                              │  copy/paste
                                              ▼
                                   sudo provision-edge.sh --api-key … ──► systemd service
                                              │  ws://10.0.0.188:8081
                                              ▼
                                   backend (Metadata.File) accepts the apikey,
                                   files it under 'bronx-05', stores to InfluxDB
```

Success = the Pi shows up as a live edge in `probe_backend.py`, its data persists
in InfluxDB (`probe_history.py`), and it coexists with OpenPLC with RAM headroom.

## Constraints (from recon of the actual device — see "Recon" below)

| Aspect | Reality | Consequence |
|---|---|---|
| OS | Raspbian 12, **32-bit (`armv7l`)** | 32-bit only; **hard-fail** if arch ≠ `armv7l` |
| RAM | 1.8 GB total, ~600 MB free, 99 MB swap | memory-capped JVM is mandatory |
| Docker | not installed | run the edge **natively**, not in a container |
| Java | not installed | install **BellSoft Liberica JRE 21** (`arm32-vfp-hflt`, confirmed available) |
| Disk | 5.1 GB free | fine for JRE + jar |
| Existing | OpenPLC on :8080 | must **coexist** (no reflash, no wipe) |

Laptop backend (from P1, still running): edge WS `ws://10.0.0.188:8081`, UI WS
`:8082`, InfluxDB `:8086`.

## The onboarding / apikey model (the core design)

P1 used `Metadata.Dummy`: the apikey *is* the edge-id, any key is accepted, and
edge identity is forgotten on restart. P2 switches the backend to
**`Metadata.File`** — a JSON registry the backend enforces. Verified format
(OpenEMS 2026.1.0 source, `io.openems.backend.metadata.file`):

```json
{
  "edges": {
    "bronx-05": {
      "apikey": "<random secret>",
      "comment": "Bronx Community Solar — SL-RP4",
      "setuppassword": ""
    }
  }
}
```

What this buys us, and the facts that shape the scripts:
- **apikey ≠ edge-id.** The edge-id (`bronx-05`, the JSON key) is the readable
  identity the backend files data under; the apikey is an independent **secret**
  the Pi presents. Unknown apikey → **rejected** (real auth, unlike Dummy).
- **`comment` is persisted free-text metadata** — the "custom metadata" slot
  (answer to the earlier question). The other metadata channel is **edge-side
  `Core.Meta`** (`placeName`, `latitude`, `longitude`, `postcode`,
  `subdivisionCode`), which the edge sends live in its EdgeConfig.
- **Identity authority is the registry, not the Pi.** The Pi config carries only
  the secret apikey; the backend resolves it → edge-id. So on the Pi, `--edge-id`
  is for *local* naming + PV scaling and should match the registered id, but is
  not what establishes identity.
- **Numeric InfluxDB id = trailing digits of the edge-id** (`bronx-05` → `5`).
  Because the registry persists, this is now **stable across backend restarts** —
  retroactively fixing the durable-identity caveat from P1 persistence. (Edge-ids
  still need globally-unique trailing numbers.)
- **The registry is read once at backend startup and cached** (no live reload).
  So registering a new edge requires a **backend restart** — `register-edge.sh`
  does this automatically (`--no-restart` to skip).
- **Backend-wide switch.** With `Metadata.File`, the P1 simulator edges must also
  be registered or they're rejected — so registration becomes the single front
  door for sim *and* real edges.

## What we build

### 1. Backend: `Metadata.Dummy` → `Metadata.File`
- Add `backend/config.d/Metadata/File.config` (factoryless singleton; path =
  pid rule applies — mind the P1 Felix path==pid gotcha), `path` →
  `/opt/openems-backend/registry/edges.json`.
- Mount a host registry file into the backend container (so scripts on the
  laptop can edit it), e.g. `./backend/registry/edges.json:/opt/.../edges.json`.
- Remove `Metadata/Dummy.config`. Confirm UI login + probe auth still work under
  File metadata.

### 2. `register-edge.sh` (runs on the laptop)
```
./register-edge.sh <edge-id> [--comment TEXT] [--place TEXT]
                             [--lat N --lon N] [--postcode P] [--region CODE]
                             [--pv-scale N] [--no-restart]
```
- Validate `<edge-id>` ends in digits and its trailing number is unique in the
  registry (collision = InfluxDB tag clash).
- Generate a random secret apikey.
- Insert/update the entry in `edges.json` (idempotent on edge-id).
- Restart the backend container (unless `--no-restart`).
- Print the exact `provision-edge.sh` command to run on the Pi, with the apikey,
  backend URI, and the place/scale flags filled in.

### 3. `provision-edge.sh` (runs on the Pi)
```
sudo ./provision-edge.sh --api-key KEY --edge-id ID --backend ws://10.0.0.188:8081
                         [--place-name TEXT] [--lat N --lon N]
                         [--postcode P] [--region CODE] [--pv-scale N]
                         [--max-mem 512M]
```
Idempotent, re-runnable:
- **Arch guard first**: `uname -m` ≠ `armv7l` → clear error, exit non-zero.
- Install Liberica JRE 21 (`arm32-vfp-hflt`) to `/opt/liberica-jre-21` if absent
  (pinned version + sha256).
- Fetch `openems-edge.jar` 2026.6.0 to `/opt/openems-edge/` if absent.
- Render `/opt/openems-edge/config.d/` from the flags — reuse P1
  `edge/entrypoint.sh` logic: `Controller/Api/Backend/ctrlBackend0.config`
  (apikey=secret, uri=backend), simulated PV datasource (scaled by `--pv-scale`
  or edge-id digits), `Core.Meta.config` (placeName/coords/postcode/region).
  **Honor the P1 path==pid rule** for every `.config`.
- Install `openems-edge.service` (systemd): runs the JRE with `-Xmx<max-mem>`,
  `-Dfelix.cm.dir=…`; unit has `MemoryMax=<max-mem>`, `Restart=on-failure`,
  `WantedBy=multi-user.target`. Enable + start.
- Print `systemctl status` summary.

### 4. Simulator-edge registration
`scale-edges.sh` companion (or a `--register` flag) so the P1 sim edges land in
`edges.json` too — otherwise File metadata rejects them. Keeps the existing
multi-edge demo working under the new front door.

## Coexistence with OpenPLC (a requirement, enforced not hoped)
- No port conflict: OpenPLC keeps :8080; the edge only makes an **outbound** WS
  connection to the laptop's :8081 — no inbound listener.
- `MemoryMax` (cgroup) means the kernel caps the JVM's RAM, so it physically
  cannot starve OpenPLC. Bring the edge up **with OpenPLC running** and record
  `free -h` before/after to prove headroom.

## Verification (same ladder as P1, on real hardware)
1. `register-edge.sh` writes the entry, backend restarts, prints the command.
2. On the Pi: `provision-edge.sh` → `systemctl status openems-edge` healthy.
3. Backend logs `Update version` for the new edge-id (apikey accepted).
4. From laptop: `probe_backend.py <edge-id>` shows live data **from the Pi**.
5. Data lands in InfluxDB; `probe_history.py <edge-id>` reads it back out.
6. `free -h` on the Pi: OpenPLC + edge coexisting with headroom.
7. Durability: restart backend, history for the Pi edge stays attributable
   (the Metadata.File fix).

## Deliverables (`prototypes/p2-edge-on-pi/`)
- `register-edge.sh`, `provision-edge.sh`, `openems-edge.service` (template),
  `config.d/` templates, backend `Metadata/File.config` + sample `edges.json`.
- `README.md` (how to run), `LEARNINGS.md` (what bit us). Merge into `prototypes`.

## Build order
1. Backend Dummy→File + register the existing sim edges; confirm P1 stack still
   works under File metadata (lowest-risk, all on the laptop).
2. `register-edge.sh` + the registry plumbing.
3. `provision-edge.sh` dry-run on the Pi (arch guard, JRE, jar, config, service).
4. End-to-end onboarding of one real Pi edge; run the verification ladder.
5. Docs + merge.

## Open items / risks
- **Liberica JRE footprint on 2 GB** with OpenPLC running — measure early; if the
  fat edge jar + JRE don't fit under a sane `MemoryMax`, fall back to a slimmed
  `.bndrun` build (built on the laptop, copied over). Start fat, measure, slim
  only if forced.
- **Metadata.File auth** — confirm UI login (`admin`) and the probe's
  `authenticateWithPassword` still succeed (File creates a single admin user;
  verify the role/getEdge dance still grants per-edge access).
- **Registry as single source of truth** lives on the laptop; back it up / keep
  it in the repo as a sample (without real secrets).

## Scope guard
P2 keeps the **simulated PV** — proves "edge runs + onboards on real hardware"
without the meter variable. Pulling a **real/MQTT meter** is P3. Securing the hop
(`wss`/TLS, the apikey currently travels in cleartext) is P4.

## Recon (captured 2026-06-28, `ssh slrp4`)
```
Raspberry Pi 4 Model B Rev 1.2 · armv7l · Raspbian 12 (32-bit)
RAM 1.8Gi (≈600Mi free), swap 99Mi · disk 14G (5.1G free)
no docker · no java · OpenPLC running on :8080
```
