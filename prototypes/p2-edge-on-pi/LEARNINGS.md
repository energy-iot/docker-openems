# P2 — what happened, what we tried, and what we learned

Goal: run the OpenEMS edge **natively on the real SL-RP4 Pi** (2 GB, 32-bit),
onboarded through a real apikey registry, coexisting with OpenPLC. Done and
verified on hardware. The work split into a backend change (metadata), two
scripts (register/provision), and the on-Pi bring-up — each taught something.

## The device is not what "Raspberry Pi 4" implies

Recon (`ssh slrp4`) found: **32-bit Raspbian (`armv7l`)**, 1.8 GB RAM, **no
Docker, no Java**, OpenPLC already running on :8080. So P1's "edge in a container
with a bundled JRE" didn't transfer — P2 runs the edge **natively**.

- **32-bit is deliberate, not broken.** Industrial Pi images ship 32-bit for
  max compatibility and a smaller per-process footprint — an advantage on 2 GB.
  We target it explicitly (`uname -m` must be `armv7l`, else hard-fail) rather
  than reflashing 64-bit (which would wipe OpenPLC — the opposite of the goal).
- **Temurin has no 32-bit-ARM JDK 21.** BellSoft **Liberica** does
  (`arm32-vfp-hflt`), and so does Azul Zulu. Verified via the BellSoft release
  API before committing to the approach. Pinned 21.0.11+11 + sha1.

## Onboarding: Metadata.Dummy → Metadata.File

To get a real "register → get apikey → provision" flow, the backend's metadata
provider had to change. `Metadata.Dummy` accepts any apikey (the apikey *is* the
id); `Metadata.File` reads a JSON registry and **rejects unknown apikeys**.

- **apikey ≠ edge-id under File.** The edge-id is the registry key (readable, its
  trailing digits → the InfluxDB tag); the apikey is an independent secret. This
  decoupling is the whole point — and it meant the Pi's edge config carries the
  *secret* while identity is resolved on the backend. (The P1 `entrypoint.sh`
  conflated the two, `apikey=EDGE_ID`; `provision-edge.sh` sets them separately.)
- **The registry is read once at startup and cached** (confirmed in source:
  `MetadataFile.refreshData()` only reads when its map is empty). So registering
  a new edge needs a **backend restart** — `register-edge.sh` does it.
- **Enforcement verified:** an unregistered apikey gets
  `Code [1003] … COMMON_AUTHENTICATION_FAILED`; a registered secret is accepted
  and resolved to the readable edge-id.
- **Bonus fix:** because edge records persist, the numeric InfluxDB id is now
  stable across restarts — closing the durable-identity gap noted in P1.

## The three things that bit us

### 1. JRE extract: `mv jre*` matched the tarball too
The Liberica tarball extracts to `jre-21.0.11/`, but the downloaded file was
`jre.tar.gz` in the same temp dir — so `mv "$tmp"/jre* "$JRE_DIR"` had **two**
sources (`jre-21.0.11` *and* `jre.tar.gz`) and a non-existent target dir →
`mv: target '…/jre': No such file or directory`. Provisioning died on the Pi.
→ Fix: extract into an isolated subdir and **locate the JRE home by its
`bin/java`** (`find … -path '*/bin/java'`) instead of globbing names. Robust to
whatever the tarball is called or unpacks to.

### 2. PV multiplier int-overflow
The simulated PV `values=i[…]` are **ints** (max ~2.1e9). The largest base value
is 4100, so a multiplier above ~520k overflows and the datasource config fails to
parse (`Integer.valueOf` throws, edge won't boot). We hit this only because a
test fed the 48-char hex apikey in as the edge-id (huge trailing number); real
edge-ids are tiny. Still a real foot-gun → `provision-edge.sh` now guards it.

### 3. Verifying "the backend accepts a new secret" needed care
The stock edge image ties `apikey=EDGE_ID`, so to test acceptance of a *secret*
apikey via a throwaway container we had to feed the secret as `EDGE_ID` — which
tripped #2. Real provisioning sets apikey and the PV-scaling id independently, so
the issue is test-only — but it's why the first acceptance probe looked like a
failure when it was an overflow.

## Coexistence with OpenPLC (the requirement) — measured

Both services run on the 2 GB box at once:
- `openplc` **active** + `openems-edge` **active**, ~1.1 GiB free.
- Edge JVM: `-Xmx384m`, systemd `MemoryMax=768M`; actual **RSS ~177 MB**.
- No port conflict (edge dials *out* to :8081; OpenPLC owns :8080). The cgroup
  cap means the kernel — not goodwill — prevents the JVM starving OpenPLC.

## Durable learnings

- **"Raspberry Pi 4" says nothing about the OS.** Always check `uname -m` and
  `free -h` first; a vendor image can be 32-bit with no Docker/Java and another
  app already resident. Provisioners must detect and adapt (or fail loudly).
- **Native + systemd + cgroup caps** is the right shape for a constrained box
  sharing duty with other software — lighter than Docker, and the memory ceiling
  is enforced by the kernel.
- **Identity vs secret:** real onboarding separates the readable edge identity
  from the secret credential. `Metadata.File` is the smallest step from Dummy
  that makes the apikey mean something — and it persists identity as a bonus.
- **Robust extraction beats name-guessing:** find the artifact you need
  (`bin/java`) rather than assuming the archive's layout.
