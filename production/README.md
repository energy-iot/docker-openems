# OpenEMS Hetzner 4 GB Pilot

This stack runs OpenEMS Backend, backend-mode UI, Keycloak, InfluxDB 2, and
Caddy on one 2-vCPU/4-GB Ubuntu VM. Images are built in GitHub Actions and the
VM only pulls immutable digests.

## 1. Prepare GitHub

1. In the OpenEMS fork, create and protect `deploy/pilot`.
2. Merge or cherry-pick the required unmerged changes onto that branch.
3. Add the custom image workflow from the fork and enable GitHub Packages.
4. Push a tag such as `pilot-v0.1.0`. Record the two image digests printed by
   the workflow; do not deploy tag-only references.
5. Configure a `production` GitHub Environment with required reviewers.

## 2. Prepare Hetzner and DNS

Create an x86 shared VM with 2 vCPU, 4 GB RAM, Ubuntu 24.04, IPv4/IPv6, and an
SSH key. Apply a Hetzner firewall allowing public TCP 80/443 and administrator
TCP 22 only. UDP 443 is optional for HTTP/3. Point both the UI and Edge DNS
names at the VM before starting Caddy.

Run provisioning on the fresh server:

```bash
sudo SSH_ALLOW_FROM=203.0.113.10/32 bash production/scripts/provision-ubuntu.sh
```

Copy `production/` to `/opt/openems`, owned by the `openems` user. Copy
`.env.example` to `.env`, insert image digests, domains, and cryptographically
random InfluxDB credentials, then set permissions to `0600`.

## 3. First deployment and OpenEMS configuration

```bash
cd /opt/openems
./scripts/deploy.sh
```

Open the Felix console only through an SSH tunnel:

```bash
ssh -L 8079:127.0.0.1:8079 openems@SERVER_IP
```

Then browse to `http://127.0.0.1:8079/system/console/configMgr`. Replace
`Timedata.Dummy` with `Timedata.InfluxDB` using:

- URL: `http://influxdb:8086`
- organization and bucket from `.env`
- API key from `INFLUXDB_TOKEN`
- the query language required by the pinned OpenEMS version

The Backend default Edge Manager port in the current image is `8093`; Caddy
publishes it as `wss://$EDGE_DOMAIN` on port 443. Register each real Edge with
the matching Backend metadata/API key rather than retaining demo credentials.

### Keycloak pilot authentication

Keycloak is capped at 768 MB and is not exposed publicly. Its persistent
embedded `dev-file` database is intentionally a single-node pilot compromise;
move it to a supported external PostgreSQL database before treating this as a
production identity service.

The first deployment imports the `openems` realm and creates the initial
`admin` user with the password from `OPENEMS_ADMIN_PASSWORD`. Change this
initial password in Keycloak after confirming the first OpenEMS login. The
deployment script also installs the matching OAuth configuration in the
Backend.

Access tokens are valid for 12 hours because the current OpenEMS backend-mode
UI does not refresh its Keycloak token. Users must sign in again when that
period expires. Reduce this lifetime when refresh-token support is added.

Open the Keycloak administration console through a separate SSH tunnel:

```bash
ssh -L 8080:127.0.0.1:8080 root@SERVER_IP
```

Then browse to `http://127.0.0.1:8080/admin/` and use
`KEYCLOAK_BOOTSTRAP_ADMIN_USERNAME` and
`KEYCLOAK_BOOTSTRAP_ADMIN_PASSWORD` from the server's protected `.env`.

## 4. Releases, snapshots, and rollback

Production deployment is manual through the protected GitHub Environment. The
workflow stops the stack, creates a crash-consistent Hetzner snapshot while the
volumes are quiet, restarts it, updates `.env` with exact image digests, and
runs health checks. Snapshot storage is billable.

Rollback without restoring data:

```bash
cd /opt/openems
./scripts/rollback.sh
```

Restore a Hetzner snapshot only when configuration or persistent data is
damaged. Snapshots are not a continuous data backup; measurements after the
snapshot can be lost.

## 5. Operations and acceptance

- `docker compose ps` and `./scripts/check.sh` show service health.
- `docker stats` shows live resource use.
- `free -h`, `swapon --show`, and `df -h` cover host capacity.
- Test UI HTTPS, UI WebSocket, Edge WSS registration, timedata writes, a VM
  reboot, and rollback before onboarding production Edges.
- Run a ten-Edge equivalent load for 24 hours. Upgrade when sustained RAM is
  above 80%, swap stays active, containers are OOM-restarted, writes lag, or
  disk latency becomes operationally visible.
- Ports 8079, 8082, 8084, 8093, and 8086 must not be reachable from the public
  internet. Port 8079 is bound to loopback solely for the SSH tunnel.
