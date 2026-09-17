# P5-A — what happened, what we tried, and what we learned

Goal: reproduce, on the stock release, the client's report that the newer
two-tier OpenEMS backend (2026.6.0) doesn't work with `Metadata.File` +
directly-connected edges (their PRs #3795–#3798). Done — reproduced two distinct
failure modes that pinpoint the blockers.

## Setup notes (two-tier is new territory)

- **Two images:** `openems/backend` (the manager tier: `Edge.Manager` :8093 +
  metadata + timedata + `Ui.Websocket` :8082) and `openems/backend-edge` (the
  `Backend.Edge.App` aggregator: edge server :8081 → manager :8093). Both exist on
  Docker Hub (2026.5/6/7, latest, develop).
- **Config seeding:** the images copy `/var/lib/openems-default-config` →
  `/var/opt/openems/config` **only if that dir is empty** (checked the s6 init
  script). So bind-mounting a non-empty config dir gives full control — that's how
  we injected Metadata.File + Timedata.InfluxDB + our manager/gateway config.
- **Stock config inconsistency:** the gateway's default `Backend/Edge/App.config`
  ships `uri="ws://localhost:8083"`, but `Edge/Manager` defaults to **port 8093**.
  Left as-is the gateway never reaches the manager. We set the gateway uri to
  `ws://openems-backend:8093`. (Worth flagging upstream.)
- The two-tier default config **already uses `Metadata.File`** — i.e. the stock
  quickstart lands you exactly in the broken scenario.

## The reproduction (how we pinned it down)

1. Tiers connect fine: `Backend.Edge.Client [edges0] connected` on the manager.
2. But the edge sat `NOT CONNECTED`, and the gateway logged **nothing** about it.
3. `netstat` inside the gateway → **:8081 not listening**, and the edge container
   couldn't reach `openems-backend-edge:8081`. Yet `Backend.Edge.App` was **active**
   (Felix console) — so not a crash; it just wasn't serving edges.
4. **Isolating experiment:** swapped *only* `Metadata.File` → `Metadata.Dummy` and
   restarted. `:8081` **immediately started listening.** That single-variable change
   proves the two-tier works and the gap is **metadata-specific**.
5. With Dummy the edge reached :8081 but got `Handshake rejected. Invalid Apikey`
   — Dummy's aggregator cache is empty (no registered edges), so the apikey isn't
   in it.

## What it means (maps to the client's PRs)

- **#3797 (Metadata.File aggregator cache):** without
  `generateUpdateMetadataCacheNotification()`, the aggregator gets no
  `apikey→edgeId` cache from the manager → **it never opens its :8081 edge server**.
  This is the primary blocker for the file-metadata stack.
- **#3796 (direct edge registration):** even with a working metadata source, a
  *directly-connected* edge must be registered into the aggregator's cache or its
  apikey is rejected / data dropped. Dummy's empty cache shows the same class of gap.
- **#3795 / #3798** (Controller.Api.Backend edge.manager flow; Influx resend) are
  *downstream* — we never reached them because the connection is blocked first.
  That ordering is consistent with the PRs.

## Durable learnings

- **The two-tier aggregator is cache-driven:** it will not serve edges until the
  manager feeds it an `apikey→edgeId` cache from the metadata provider. Current
  released metadata impls don't do this for directly-connected edges → the whole
  edge path is dead on arrival with file metadata.
- **Our monolithic 2026.1.0 choice (P1–P4) is validated again** — it sidesteps all
  of this. The two-tier is a post-August-release option (or build from the PR
  branches = P5-B).
- **Debugging OSGi "it's active but does nothing":** component `active` ≠ doing its
  job. Check what it *should* have opened (a port), not just its DS state — the
  `netstat` + single-variable metadata swap was what turned "it's broken" into
  "it's broken *here*, for *this* reason."
