# P2 — OpenEMS edge on the SL-RP4 Pi, with real onboarding

The second prototype for [energy-iot/docker-openems#79](https://github.com/energy-iot/docker-openems/issues/79):
take the edge that ran in a laptop container in P1 and run it **natively on the
actual Raspberry Pi** (Synergy Logic SL-RP4, 2 GB, 32-bit) — provisioned by a
repeatable script, onboarded through a real apikey registry, and **coexisting
with OpenPLC** on the same box.

```
   LAPTOP                                              SL-RP4 Pi (10.0.0.121)
 ┌────────────────────────────┐                     ┌──────────────────────────┐
 │ backend (Metadata.File)     │                     │ OpenPLC        :8080      │ ← untouched
 │  registry: edges.json       │   ws ://…:8081      │ openems-edge.service      │
 │  + InfluxDB + UI (from P1)  │ ◄─────────────────  │  Liberica JRE 21 (arm32)  │
 └──────────┬──────────────────┘   secret apikey     │  -Xmx384m, MemoryMax 768M │
            │                                         │  simulated PV (×N)        │
   ① register-edge.sh  ───────────────────────────►  └──────────────────────────┘
     (issues apikey + prints the provision command)      ② provision-edge.sh
```

Where P1 proved "telemetry reaches the cloud," P2 proves "the edge runs on the
real, constrained device and onboards like a real one would." It reuses the P1
backend/InfluxDB/UI as-is — only the **metadata** layer changed (Dummy → File).

## The two-step flow

**① On the laptop — register the edge** (issues a secret apikey, writes it to the
backend's registry, restarts the backend to load it, prints the command to run):
```bash
cd prototypes/p2-edge-on-pi
./register-edge.sh slrp4-09 --place "SL-RP4 Bench" --comment "Synergy Logic SL-RP4"
# ✅ Registered edge 'slrp4-09' ...
#    sudo ./provision-edge.sh --edge-id slrp4-09 --api-key 4fb9…6961 \
#         --backend ws://10.0.0.188:8081 --place-name "SL-RP4 Bench"
```
- `<edge-id>` must end in **globally-unique digits** (the InfluxDB tag — collisions
  are refused). `--rotate` issues a fresh apikey; `--no-restart` skips the bounce.

**② On the Pi — provision** (copy the printed command over and run it):
```bash
scp provision-edge.sh slrp4:~/            # one time
ssh slrp4
sudo ./provision-edge.sh --edge-id slrp4-09 --api-key 4fb9…6961 \
     --backend ws://10.0.0.188:8081 --place-name "SL-RP4 Bench"
```
Idempotent. It installs the JRE + edge jar, renders config, and starts a
memory-capped `systemd` service. Flags: `--lat/--lon/--postcode/--region`
(→ `Core.Meta`), `--pv-scale N` (PV multiplier), `--max-mem 384M` (JVM heap;
the cgroup cap is derived as heap + 384 MiB). `--dry-run` renders the config to a
temp dir on any machine without installing — handy to preview.

## What provision-edge.sh does (native, no Docker)

1. **Hard-fails unless `armv7l`** — this prototype targets 32-bit Raspberry Pi OS.
2. Installs **BellSoft Liberica JRE 21** (`arm32-vfp-hflt`, pinned + sha1-verified)
   to `/opt/openems-edge/jre` — Temurin has no 32-bit-ARM JDK 21; Liberica does.
3. Downloads `openems-edge.jar` (2026.6.0) to `/opt/openems-edge`.
4. Renders `/opt/openems-edge/config.d` from the flags (secret apikey in
   `ctrlBackend0`, simulated PV scaled, `Core.Meta` site info), honoring the
   Felix **path == pid** rule (see P1 LEARNINGS).
5. Installs `openems-edge.service`: `java -Xmx<heap> … -jar …` with systemd
   `MemoryMax`/`MemoryHigh` so the kernel hard-caps the JVM — it can't starve
   OpenPLC. Enabled on boot, `Restart=on-failure`.

## Onboarding & the apikey (Metadata.File)

The backend now runs **`Metadata.File`** instead of `Metadata.Dummy`. It reads a
JSON registry (`../p1-edge-to-backend/backend/registry/edges.json`) and **rejects
any apikey not in it** (`COMMON_AUTHENTICATION_FAILED`). Each entry:
```json
"slrp4-09": { "apikey": "<secret>", "comment": "free-text metadata" }
```
- **apikey ≠ edge-id.** The edge-id (`slrp4-09`) is the readable identity the
  backend files data under; the apikey is an independent secret the Pi presents.
- The registry **persists**, so the InfluxDB numeric id (trailing digits of the
  edge-id) is stable across restarts — this also fixed P1's "Dummy forgets edge
  identity on restart" caveat.
- The backend reads the registry **once at startup**, so `register-edge.sh`
  restarts it after writing (that's the bounce; `--no-restart` to defer).

> Switching to File is backend-wide: the P1 simulator edges are registered too
> (their apikey is just their id — not secret). So registration is now the single
> front door for sim and real edges alike.

## Verify (the ladder, on real hardware)

```bash
# on the Pi
systemctl status openems-edge          # active (running)
journalctl -u openems-edge -f          # live edge log

# from the laptop
python3 ../p1-edge-to-backend/probe_backend.py slrp4-09    # live data FROM the Pi
python3 ../p1-edge-to-backend/probe_history.py slrp4-09    # persisted in InfluxDB
```
Confirmed on the SL-RP4: edge authenticates and registers, streams live PV
(24 kW at ×10) over the LAN, data persists in InfluxDB, and it **coexists with
OpenPLC** — both services active, ~1.1 GiB free, edge RSS ~177 MB under the
768 MiB cap.

## Coexistence with OpenPLC

No port conflict (OpenPLC keeps :8080; the edge only dials *out* to :8081). The
cgroup `MemoryMax` means the kernel caps the JVM, so it physically cannot starve
OpenPLC. To stop/disable the edge without touching OpenPLC:
```bash
sudo systemctl stop openems-edge      # stop now
sudo systemctl disable openems-edge   # don't start on boot
```

## What's next (per the ticket ramp)

- **P3** — Mosquitto + a dummy meter publishing to topic `OpenAMI`; the Pi edge
  ingests it as a channel (swap the simulator for the MQTT meter).
- **P4** — secure the edge→backend hop. Note the apikey currently travels as a
  cleartext header over `ws://` — P4 puts TLS in front (`wss://`).
