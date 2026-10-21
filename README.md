# VPS Monitoring (Docker Compose)

Collector bundle for one VPS: host metrics, container metrics and the Traefik access
log, shipped to a central Prometheus/Grafana/Loki stack. All three collectors reach
the central stack **only through a dedicated, isolated WireGuard client**; the host
network configuration is not modified and **no published ports** exist.

This repo is the collector side only. It does not run Prometheus, Grafana or Loki, and
the central WireGuard hub lives in the central monitoring repository.

> Deploying on Dokploy? Use **[docs/vpn-dokploy.md](docs/vpn-dokploy.md)**: it is the
> end-to-end operator guide (peer export, File Mounts, firewall, verification,
> recovery, removal). This README is the front door for a local checkout.

---

## Network model

```
        central hub (other repo)                     this VPS
  ┌──────────────────────────────┐        ┌──────────────────────────────────────┐
  │ Prometheus   Loki            │        │ namespace A  (vpn container only)     │
  │ wg0 = 10.77.0.1              │        │  wg0 = 10.77.0.2/32                   │
  └──────────────┬───────────────┘        │  node_exporter :9100                  │
                 │ public UDP 51820       │  cadvisor      :8080                  │
                 └────────────────────────┤  alloy -> http://10.77.0.1:3100/...    │
                                          │    (all three: network_mode service:vpn)│
                                          └───────────────┬──────────────────────┘
                                                          │ vpn_egress bridge
  ┌────────────────────────────────────────────────────────┴─────────────────────┐
  │ host: no wg0, no routes, no DNS, no firewall change, no published ports      │
  └──────────────────────────────────────────────────────────────────────────────┘
```

One namespace holds `wg0`; the three collectors join it. The host, host routes, host
DNS, sysctls, host firewall rules and Traefik are untouched.

---

## Services

| Service | Image | Purpose | Published ports |
| --- | --- | --- | --- |
| `vpn` | `lscr.io/linuxserver/wireguard:1.0.20260223-r0-ls126` | Owns the isolated namespace, builds `wg0`, installs the in-namespace guard | none |
| `node_exporter` | `prom/node-exporter:v1.10.2` | Host CPU/RAM/disk/filesystem metrics | none |
| `cadvisor` | `gcr.io/cadvisor/cadvisor:v0.52.0` | Per-container metrics | none |
| `alloy` | `grafana/alloy:v1.20.1` | Traefik access log -> central Loki | none |

**No published ports.** The exporters are reachable only from the central hub through
the tunnel, at the peer tunnel address (`10.77.0.2:9100`, `10.77.0.2:8080` in this
example). Container state, not connectivity, is what `docker compose ps` shows.

---

## Configuration

`cp env.example .env`, then fill it in. `.env` is git-ignored; `env.example` is tracked,
so keep it free of real values.

| Variable | Required | Description |
| --- | --- | --- |
| `VPS_NAME` | yes | Short unique name (`[A-Za-z0-9._-]+`), becomes the `vps` log label |
| `LOKI_PUSH_URL` | yes | Full push URL on the **hub tunnel address**, for example `http://10.77.0.1:3100/loki/api/v1/push` |
| `VPN_ENDPOINT_IP` | no | Hub public IPv4 when the client config's `Endpoint` is a DNS name |
| `VPN_EXPORTER_PORTS` | no | Ports Prometheus scrapes through the tunnel (default `9100,8080`) |
| `VPN_HANDSHAKE_MAX_AGE` | no | Max handshake age in seconds for `vpnctl verify` (default `180`) |
| `VPN_SUPERVISE_INTERVAL` | no | VPN supervisor period in seconds (default `10`) |
| `WG_CONFIG_PATH` | no | Host path of the client config mount (default `./files/wg0.conf`; Dokploy: `../files/wg0.conf`) |
| `WG_CONFIG_BASE64` | no | Base64 of the whole config. **Not the default**: base64 is not encryption |

Do not set `VPN_CONFIG_FILE`: the container default `/config/wg0.conf` is already
correct, and setting it alongside `WG_CONFIG_BASE64` is rejected as ambiguous.

The client config is a real WireGuard client file generated for this VPS by
`scripts/vpn/peer.sh show <name>` on the central VPS. It contains the peer private
key, so it is **never committed**: `files/wg0.conf` is git-ignored.
[`files/wg0.conf.example`](files/wg0.conf.example) is the fake template.

---

## Local quick start

```bash
# 1. Put the exported client config in place (never commit it).
mkdir -p files && cp /path/to/exported/wg0.conf files/wg0.conf

# 2. Dummy-check the config without touching the network.
env VPS_NAME=x LOKI_PUSH_URL='http://10.77.0.1:3100/loki/api/v1/push' \
  VPN_CONFIG_FILE=files/wg0.conf.example sh files/vpnctl check-config

# 3. Configure and start.
cp env.example .env          # then edit VPS_NAME / LOKI_PUSH_URL
docker compose up -d
docker compose ps

# 4. Readiness, then connectivity (different claims).
docker compose exec vpn /bin/sh /opt/vpn/vpnctl status
docker compose exec vpn /bin/sh /opt/vpn/vpnctl verify
```

`status` reports the readiness marker, interface, hub route, guard, handshake age and
transfer totals. `verify` is the only command that claims connectivity: it exits 1
when no handshake exists or the last one is older than `VPN_HANDSHAKE_MAX_AGE`.
`docker compose logs -f vpn` follows logs; `docker compose down` keeps `alloy_data`.

---

## Prometheus (point it at the tunnel address)

The exporters have no host port, so scrape the **peer tunnel address**, never a public
VPS IP:

```yaml
scrape_configs:
  - job_name: "vps-node-exporter"
    static_configs:
      - targets: ["<PEER_TUNNEL_IP>:9100"]   # e.g. 10.77.0.2:9100

  - job_name: "vps-cadvisor"
    static_configs:
      - targets: ["<PEER_TUNNEL_IP>:8080"]   # e.g. 10.77.0.2:8080
```

Prometheus must run where the tunnel is reachable (on the hub, its own `wg0`).

---

## Logs (Alloy -> Loki)

`alloy` tails `/var/log/traefik/access.log`, labels every stream with
`job="traefik"` and `vps="$VPS_NAME"`, and pushes to `LOKI_PUSH_URL`. The read-only
Traefik directory mount and the persistent `alloy_data` positions volume are preserved.

| Format | How it is parsed | Labels available |
| --- | --- | --- |
| `common` (Traefik/Dokploy default) | `stage.regex` | `method`, `status` |
| `json` | `stage.json` | `method`, `status`, `router`, `service` |

`client_ip` and `path` stay in the log line and are never promoted to labels.

```logql
{job="traefik", vps="vps-1"} |= "500"
{job="traefik", vps="vps-1", status="502"}
```

There is no write-ahead log: unsent entries wait in a bounded in-memory queue and can
be lost on restart or a long outage. There is no exactly-once delivery. Container logs
are bounded (`json-file`, `10m` x `3`).

### Dokploy and the three files

`files/vpnctl` and `files/config.alloy` are committed, so the Dokploy clone already
has them and no File Mount is needed. Only the secret `wg0.conf` comes from a
Dokploy **File Mount** (`wg0.conf`), and the compose mount reads it through
`WG_CONFIG_PATH` — set `WG_CONFIG_PATH=../files/wg0.conf` in Dokploy, leave the
default `./files/wg0.conf` for a local checkout. See
[`docs/vpn-dokploy.md`](docs/vpn-dokploy.md) §5.

Do not rewrite the `vpnctl` / `config.alloy` mounts to `../files/`: Docker turns a
missing bind source into an empty directory and the service fails or restart-loops.

--- | --- | --- |
| Repository | `files/config.alloy` | `docker compose` on a local checkout |
| Dokploy | `/etc/dokploy/compose/<app>/files/config.alloy` | the deployed service (File Mount) |

Editing the repository copy does not change the deployed pipeline: paste the content
into the Dokploy File Mount. The same two copies exist for `files/vpnctl` and
`files/wg0.conf`.

---

## Metrics semantics

| Signal | Source |
| --- | --- |
| Host CPU, memory, disk, filesystem | host-mounted `/host/proc`, `/host/sys`, `/rootfs` — unchanged |
| Host NIC counters | `vpnctl hostnet-loop` reads `/host/proc/1/net/dev`; node_exporter textfile collector exposes `node_network_*{source="hostnet"}` |
| Container CPU/memory/IO | cAdvisor, unchanged |
| Network-namespace-scoped collectors | disabled (`netdev`, `netclass`, `netstat`, `sockstat`, ...); do not re-enable them |

`hostnet_metrics_available 0` means the host NIC read was denied (kernel or AppArmor):
counters are absent, never wrong. Per-container `container_network_*` series for these
three containers describe the shared VPN namespace, not host totals.

---

## Security notes

- **No public ports, no host network namespace.** No service uses `network_mode: host`
  or publishes a port; `vpn` adds only `NET_ADMIN` and drops every other capability.
- **cAdvisor stays privileged.** Its host mounts are required for container metrics, so
  the tunnel is *network scoping*, not a security boundary against a compromised
  privileged cAdvisor.
- **`WG_CONFIG_BASE64` is not a secret.** `docker inspect` and any local Docker
  administrator can read it. Use the read-only File Mount.
- **Traffic cannot fall back to public egress:** the default route is removed after the
  hub endpoint route is pinned, and the namespace guard is default-DROP.

---

## Troubleshooting

**`vpn` is unhealthy / restart-loops ("not ready").** `vpnctl` only writes the
readiness marker after `wg0`, the hub route and the guard verify. Read the field named
in the log (never a key value) with `docker compose logs vpn`.

**"cannot create wg0: the wireguard kernel module must be loaded".** The host has no
`wireguard` module. Ubuntu 20.04+ ships it; do not add `SYS_MODULE` or
`/lib/modules` here and do not create `wg0` on the host.

**`verify` says "no handshake ... (never)".** The tunnel is built but the hub never
answered. Check the provider firewall (outbound UDP `51820` to the central public IP),
that the central hub is up, and that the peer is still enrolled centrally.

**Collectors look alive but the hub sees nothing (stale namespace).** Recreating only
`vpn` gives it a new namespace and leaves the collectors on the old one. Check and
repair:

```bash
export COMPOSE_FILE=/etc/dokploy/compose/<app>/code/docker-compose.yml
export COMPOSE_PROJECT_NAME=<app>
scripts/vpn-redeploy.sh --check
scripts/vpn-redeploy.sh
```

**`hostnet_metrics_available 0`.** The host NIC read was denied. Host NIC counters are
missing rather than wrong; fix the read permission, do not re-enable `netdev`.

**Loki is down.** Alloy retries in memory, `docker compose ps` still shows `running`,
and nothing is sent publicly. Expect gaps for the outage window.

**`vpn` starts but the deploy says it is unhealthy.** The reason is in
`docker compose -p <app> logs --tail 100 vpn` (vpnctl never prints key material).
Frequent causes: the `wg0.conf` File Mount missing or `WG_CONFIG_PATH` unset
(`configuration path is a directory`), `LOKI_PUSH_URL` not being the hub tunnel
address (`not covered by AllowedIPs`), no `wireguard` module on the host
(`cannot create wg0`), or the fake template mounted instead of the real file
(`invalid PrivateKey`).

`ambiguous configuration input` means `WG_CONFIG_BASE64` has a value **and** the
mounted file exists: remove the variable from Dokploy's Environment tab. Use
`sudo docker logs vpn` (or `docker compose -p <app> logs vpn`) to read the reason.

---

## Tests

Deterministic, offline, no Docker daemon and no key material required:

```bash
bash tests/run.sh
```

It runs every `tests/test_*.sh` in sorted order and exits non-zero if any suite fails.
Individual suites: `test_vpnctl_config.sh`, `test_vpnctl_setup.sh`,
`test_vpnctl_hostnet.sh`, `test_compose_contract.sh` (skips without the Docker CLI),
`test_redeploy_contract.sh`, `test_docs_contract.sh`.

The suite never starts a container. A separate local Docker Desktop sandbox (fake keys,
fake hub, no published ports, torn down afterwards) was used once during development to
exercise the real container path; it is not part of the suite and it is not the VPS
pilot.

---

## Changed in this revision

- The exporters no longer publish host ports (`9100`, `8080`). They are reachable only
  through the isolated WireGuard tunnel at the peer tunnel address.
- A dedicated `vpn` service owns the only namespace with `wg0`; `node_exporter`,
  `cadvisor` and `alloy` join it with `network_mode: "service:vpn"`.
- Host metrics are preserved: host procfs/sysfs/rootfs mounts are unchanged, and host
  NIC counters come from a textfile written by `vpnctl`.
- Already-deployed VPS stacks that still use the old files keep working until they are
  redeployed; redeploying them switches them to the tunnel-only model.
- Other VPSs, the central stack and the developer VPN are unaffected.

Good for: exporting host + container metrics and Traefik access logs from a VPS over a
private tunnel into a central stack. Not included: Prometheus, Loki, Grafana
dashboards, alert rules, and Docker container stdout logs (only the Traefik access log is
shipped).
