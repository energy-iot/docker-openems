# Note: Grafana on top of the InfluxDB persistence layer (not built yet)

P1 persists telemetry to InfluxDB (see README "Persistence layer"). The natural
next visualization step — and how operators actually watch a *fleet* of sites —
is **Grafana** pointed at that InfluxDB as a data source. OpenEMS's own UI shows
one edge at a time; Grafana is where you build cross-edge dashboards
(all sites' production on one panel, alerting on a site going dark, etc.).

This is a **deferred follow-up**, captured so we don't lose it. Not wired into the
compose stack yet — we moved on to P2 (edge on the Pi).

## When we do it — the whole thing is ~15 lines of compose

Add a service (the InfluxDB connection details are the ones from
`docker-compose.yml`):

```yaml
  grafana:
    image: grafana/grafana-oss:latest
    container_name: openems-grafana
    depends_on: [influxdb]
    environment:
      GF_SECURITY_ADMIN_USER: admin
      GF_SECURITY_ADMIN_PASSWORD: admin       # dev only
    volumes:
      - grafana-data:/var/lib/grafana
    ports:
      - "3000:3000"
    restart: unless-stopped
# and add `grafana-data:` under the top-level `volumes:` key
```

Then open http://localhost:3000 (admin/admin) and add an InfluxDB data source:

| Field | Value |
|-------|-------|
| Query language | Flux |
| URL | `http://influxdb:8086` |
| Organization | `openems.io` |
| Token | `openems-p1-dev-token` |
| Default bucket | `openems` |

Starter Flux query for a panel (production per edge, last 6h):

```flux
from(bucket: "openems")
  |> range(start: -6h)
  |> filter(fn: (r) => r._field == "_sum/ProductionActivePower")
  |> aggregateWindow(every: 1m, fn: mean)
  |> group(columns: ["edge"])     // one line per site
```

## To make it reproducible (the proper version)

Hand-clicking the data source defeats the "comes up from one `docker compose up`"
ethos. Provision it instead via files mounted into
`/etc/grafana/provisioning/{datasources,dashboards}/` so the data source and a
starter dashboard exist on first boot — same spirit as how InfluxDB
auto-bootstraps its org/bucket/token today.

## Gotchas to remember

- **Edge tag is a number, not the name.** `edge="1"`, not `"bronx-01"`. Grafana
  panels will show `1/2/3/4`; map them with a Grafana *value mapping* or a
  variable if you want readable site names. (Same Metadata.Dummy limitation noted
  in LEARNINGS — the name↔number map lives in the backend, not InfluxDB.)
- **Field names contain slashes** (`_sum/ProductionActivePower`) — fine in Flux
  string filters, just don't expect bare-identifier syntax.
- Use Flux here even though OpenEMS itself queries with InfluxQL; for Grafana
  exploration Flux is the smoother path.
