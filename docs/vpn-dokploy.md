# Dokploy operator guide: isolated WireGuard client for the VPS monitoring stack

This stack runs one monitoring collector bundle per VPS: `node_exporter`, `cadvisor`
and `alloy` share the network namespace of a dedicated WireGuard client container
named `vpn`. They have no published ports, no Docker network of their own, and no
route to the internet except the tunnel. The host is not modified.

Read section 4 for the short path. Every other section explains one promise the
stack makes and how to verify it. Nothing in this repository was deployed, so
section 13 lists exactly what is still unproven.

---

## 1. What this does and does not do

**Does:**

- The `vpn` container owns the only network namespace that has `wg0`. `vpnctl`
  (`files/vpnctl`) creates the interface, the `/32` peer address, the hub route and
  an in-namespace iptables guard, then removes the default route after pinning the
  hub endpoint. From then on the namespace can only reach the hub.
- The three collectors join that namespace with `network_mode: "service:vpn"` and
  are reachable only from the central hub through the tunnel.
- `vpn` joins exactly one dedicated bridge, `vpn_egress`. That bridge is only the
  path WireGuard needs to reach the hub's public UDP endpoint; it is not the
  isolation mechanism and no other application joins it.
- The namespace guard covers IPv4 and locks IPv6 down to loopback only: the tunnel
  carries IPv4 only, so a namespace that gets an IPv6 address cannot become a
  public egress path around the guard.

**Does not:**

- It does not create a `wg0` interface on the host, and does not use
  `network_mode: host` or a host network-namespace mount.
- It does not change host routes, host DNS (`/etc/resolv.conf`), sysctls, host
  firewall rules, or Traefik. There is no Docker socket and no `SYS_MODULE` on any
  service.
- It publishes no public exporter ports: no `9100:9100`, no `8080:8080`, no `3100`.
- It is not a security boundary. cAdvisor stays `privileged: true` with its existing
  host mounts, because container metrics need them. A compromised privileged cAdvisor
  can read host state regardless of the namespace it shares. Treat the isolation as
  **network scoping, not a boundary** against a compromised privileged collector.

---

## 2. Prerequisites

| Prerequisite | Detail |
| --- | --- |
| Linux VPS | Must have the `wireguard` kernel module available. Ubuntu 20.04+ ships it; nothing is installed with DKMS here. |
| No host `wg0` | Do not create a WireGuard interface on the host. When `vpnctl` runs `ip link add dev wg0 type wireguard` inside the container namespace, the kernel autoloads the module. If that call fails, the module is missing on the host: fix the host, do not add `SYS_MODULE` or `/lib/modules` to this stack. |
| Docker + Dokploy | Docker with the Compose plugin. |
| Central hub | Reachable on its public **UDP** port (default `51820`). The hub itself is managed by the central repository; this template never changes it. |
| Dokploy Compose type | **Docker Compose**, not **Stack**. |

### Dokploy Compose type: "Docker Compose", not "Stack"

When you create the service, select the Compose type **Docker Compose**.

**Stack** is not supported. Dokploy's *Stack* type deploys through Docker Swarm, and
Swarm does not support Compose `network_mode` or `network_mode: "service:<name>"`
(see the compose-vs-stack distinction in the Dokploy documentation and moby/moby#33055).
Under Swarm the three collectors could not join the VPN namespace, so they would run
in their own namespaces with no tunnel and no published port: the stack would be
unreachable with no obvious error.

---

## 3. SCM prerequisites (list only, never edit SCM)

These are the only things the central repository must provide. Do not edit the
central repository from the VPS side, and do not change the hub's host-network VPN
project or its firewall guard: the client design here assumes they stay as they are.

1. **Peer name: alphanumeric only** (`[A-Za-z0-9]`). The WireGuard image skips names
   containing `-`, `_`, `.` or a space and generates no configuration for them at all,
   so a name like `vps-1` produces no file and the export step fails.
2. **Export the client config on the central VPS** with
   `scripts/vpn/peer.sh show <name>`. That output contains the peer **private key**.
   Transfer it out of band (SSH/`scp`, an approved secret manager). Never paste it into
   chat, a ticket, a commit or CI logs.
3. **`WG_SERVERURL` should be the central public IPv4.** If it is a DNS name instead,
   the client resolves it once at container start, which needs a working resolver in
   the source namespace. Set `VPN_ENDPOINT_IP` on the VPS to the hub public IPv4 to
   skip that resolution step entirely.
4. **The generated `DNS =` line is ignored by design.** `vpnctl` validates its shape
   and never applies it: nothing inside the isolated namespace reads
   `/etc/resolv.conf`, because both ends of the tunnel are addressed by IP.
5. **Keep the hub's host-network VPN project and its guard unchanged.** The hub does
   the peer-to-peer and public-egress filtering; this client only filters its own
   namespace.

---

## 4. Operator sequence

1. **Enrol one peer in SCM and export it** (central VPS, per section 3): append the
   alphanumeric name to `WG_PEERS`, redeploy the VPN project, then run
   `scripts/vpn/peer.sh show <name>` and move the output to your workstation out of
   band. Confirm the blob contains `Address`, `PrivateKey`, `ListenPort`, `DNS`,
   `PublicKey`, `PresharedKey`, `AllowedIPs` and `Endpoint`.
2. **Import it into the VPS Dokploy Compose service as a File Mount.** Advanced ->
   Mounts -> File Mount: File Path `wg0.conf`, Mount Path `/config/wg0.conf`, Content =
   the exported file. Add the other two File Mounts from section 5 (`vpnctl`,
   `config.alloy`) and rewrite every `./files/` mount to `../files/`.
3. **Set `VPS_NAME` and the private `LOKI_PUSH_URL`.** `VPS_NAME` is a short unique
   name matching `[A-Za-z0-9._-]+` (it becomes the `vps` log label).
   `LOKI_PUSH_URL` is the hub **tunnel** address, for example
   `http://10.77.0.1:3100/loki/api/v1/push`. A public or hostname endpoint is
   rejected at startup, so logs cannot leave un-tunnelled.
4. **Add the provider firewall rules** from section 6: outbound UDP to the central
   public IP on `51820`. Open nothing else.
5. **Deploy** the stack in Dokploy. `vpn` starts first, its healthcheck gates the
   three collectors, and the collectors are created against the VPN namespace.
6. **Verify handshake, central scrape and Loki ingestion** with section 7. Do not
   skip `vpnctl verify`: it is the only command that proves connectivity.
7. **Restart or recreate safely** with `scripts/vpn-redeploy.sh` (never a bare
   `docker restart vpn`), then run the same verification again.
8. **Remove safely**: section 12.

---

## 5. Dokploy File Mounts

Three files are mounted, all read-only. Create each one in the Dokploy UI under
**Advanced -> Mounts -> File Mount**; the File Path is a name relative to the app's
`files/` directory.

| Repository path | Dokploy File Path (Advanced -> Mounts) | Container mount path | Why |
| --- | --- | --- | --- |
| `files/vpnctl` | `vpnctl` | `/opt/vpn/vpnctl` | The entrypoint and healthcheck. It validates the client config, builds the tunnel, installs the guard and writes the readiness marker. |
| `files/wg0.conf` (never committed; `files/wg0.conf.example` is the template) | `wg0.conf` | `/config/wg0.conf` | The per-VPS client configuration exported on the central VPS. Contains the peer private key. |
| `files/config.alloy` | `config.alloy` | `/etc/alloy/config.alloy` | The Traefik access-log pipeline that pushes to the central Loki over the tunnel. |

### The `./files/` -> `../files/` rewrite

Dokploy keeps the Compose file at `/etc/dokploy/compose/<app>/code/docker-compose.yml`,
so its durable files live one level up in `/etc/dokploy/compose/<app>/files/`.
Rewrite **every `./files/` occurrence** in `docker-compose.yml` to `../files/`:

```yaml
- ../files/vpnctl:/opt/vpn/vpnctl:ro
- ../files/wg0.conf:/config/wg0.conf:ro
- ../files/config.alloy:/etc/alloy/config.alloy:ro
```

Repository-relative mounts (`./files/...`) are wiped by Dokploy's AutoDeploy: the
deployed directory is replaced, so a file that only exists in the repository copy is
gone after the next deploy. Durable files live in `<app>/files/`, which is what the
File Mounts write and what `../files/...` resolves to.

### Two copies of every mounted file

| Copy | Path | Used by |
| --- | --- | --- |
| Repository | `files/vpnctl`, `files/config.alloy` | `docker compose` on a local checkout |
| Dokploy | `/etc/dokploy/compose/<app>/files/...` | the deployed service |

They are independent files. Editing the repository copy does not change the deployed copy:
paste the updated content into the File Mount and redeploy. Otherwise the VPS
keeps running the old script or pipeline with no error to tell you.

---

## 6. Provider firewall

Provider firewalls are yours to manage; this repository never touches them. Only the
WireGuard UDP transport needs a rule. The monitoring traffic inside it is decrypted
from the tunnel, so it needs no provider rule (the in-namespace guard governs it).

| Direction | Source / destination | Protocol | Port | Required |
| --- | --- | --- | --- | --- |
| Outbound | this VPS -> central public IPv4 (`WG_SERVERURL`) | UDP | `51820` | Yes: handshake and keepalive |
| Inbound | central public IPv4 -> this VPS | UDP | `51820` | No rule needed: return traffic is stateful on every mainstream provider firewall and security group |

**Why there is no fixed inbound client listen port to open.** This stack publishes no
port at all, so Docker creates no host-side listener and the provider firewall has
nothing to admit. The generated `ListenPort = 51820` is the *outer* source port of the
NAT mapping the client's own packets create; the generated `PersistentKeepalive = 25`
refreshes that mapping every 25 seconds, which is what keeps the hub able to answer.
`vpnctl` passes `ListenPort` through to `wg` unchanged, but that socket lives inside
the container namespace and is never published on the host.

Never open `9100`, `8080` or `3100` publicly, in either direction. The exporters and
Loki are reached only from the central hub through the tunnel; a public rule for them
would defeat the whole design and expose an unauthenticated metrics or log endpoint.

---

## 7. Verification commands and what each one proves

Run these on the VPS unless marked CENTRAL.

| Command | Proves | Does not prove |
| --- | --- | --- |
| `docker compose ps` | container state only (running/healthy per Docker) | that `wg0` exists, that a handshake happened |
| `docker exec vpn /bin/sh /opt/vpn/vpnctl status` | readiness marker, interface, address, hub route, guard, handshake age, transfer totals | that the hub can still reach the exporters |
| `docker exec vpn /bin/sh /opt/vpn/vpnctl verify` | a handshake exists and is younger than `VPN_HANDSHAKE_MAX_AGE`; exit code 0/1 | log ingestion, scrape success |
| CENTRAL: `scripts/vpn/peer.sh list` | the peer is known to the hub and shows a live handshake | that the collectors are serving |
| CENTRAL: Prometheus target state for this peer | scrapes of `<PEER_TUNNEL_IP>:9100` and `:8080` succeed | that logs arrive |
| CENTRAL: Loki query `{job="traefik", vps="<name>"}` | the Alloy pipeline pushes through the tunnel | request-level completeness (see section 9) |

Two claims are deliberately separate:

- **A running container does not prove `wg0`.** Docker can report `running` for a
  container whose entrypoint has not yet built the interface.
- **a configured interface does not prove a handshake.** `status` can show `wg0` up
  with `handshake: never`, which means the tunnel is built but the hub never answered.
  `vpnctl verify` is the only connectivity claim; `vpnctl status` is readiness plus
  observations.

Expected shapes:

```bash
$ docker exec vpn /bin/sh /opt/vpn/vpnctl status
readiness: ready (/run/vpn/ready)
hub: 10.77.0.1
endpoint: 203.0.113.10:51820
handshake age: 41s
transfer: rx=18234 tx=9012

$ docker exec vpn /bin/sh /opt/vpn/vpnctl verify
connectivity: handshake ok (41s old)
```

A `status` exit code of 0 means the readiness marker exists; it says nothing about
connectivity. `verify` exits 1 with `connectivity: no handshake with the hub yet
(never)` or `connectivity: handshake is stale (Ns old, max Ns)` when the tunnel is not
working.

---

## 8. Failure behaviour

**The central hub is offline.** `wg0` stays up and the guard stays installed; no
handshake completes. Alloy keeps retrying its push in memory, Prometheus scrapes fail,
`vpnctl verify` exits 1. **Nothing falls back to public egress:** the default route is
removed after the endpoint host route is pinned, and the namespace guard is
default-DROP, so a push cannot silently leave over the public interface. When the hub
returns, the generated `PersistentKeepalive = 25` re-establishes the tunnel without a
restart.

**The VPN container crashes.** Docker restarts it (`restart: unless-stopped`) and it
creates a **new** network namespace. The three collectors still point at the old,
dead namespace: they look alive but are unreachable from the hub. This is the one case
Compose cannot repair. Run:

```bash
# On the VPS host, as root or a user in the `docker` group. Point both variables at
# the file Dokploy uses: its .env sits next to it, so ${VPS_NAME}/${LOKI_PUSH_URL}
# interpolate exactly as they do in a Dokploy deploy.
export COMPOSE_FILE=/etc/dokploy/compose/<app>/code/docker-compose.yml
export COMPOSE_PROJECT_NAME=<app>

scripts/vpn-redeploy.sh --check   # read-only: healthy? every collector attached?
scripts/vpn-redeploy.sh           # recreate vpn + collectors, wait, re-check
```

`vpn-redeploy.sh` recreates `vpn`, `node_exporter`, `cadvisor` and `alloy` in one
ordered `docker compose up -d --force-recreate`, waits for the VPN healthcheck, then
verifies that each collector's `HostConfig.NetworkMode` is
`container:<current vpn id>`. `--check` is read-only: exit 0 means healthy and
attached, exit 1 means stale or unhealthy. Use `--project <name>` instead of
`COMPOSE_PROJECT_NAME` if you prefer. Unrelated applications are never touched.

**`docker restart vpn` or `--force-recreate vpn` alone leaves stale collectors.** The
recreate gives the VPN a new namespace id, and the existing collectors keep the old
one. Their containers stay `running`, so `docker compose ps` looks fine while the hub
sees nothing. That is exactly why the recovery script exists: `--check` reports the
stale `NetworkMode` per collector.

**A configuration error restart-loops the VPN container.** `vpnctl` exits non-zero
before writing the readiness marker, so the healthcheck never passes and the three
collectors are never started. This is fail-closed by design: no tunnel means no
collectors. The logs name the offending field or directive only (for example
`vpnctl: invalid PresharedKey: expected a 44-character base64 key`) and never echo a
key value:

```bash
docker compose logs vpn
```

Frequent causes: a File Mount that was not created (Docker turns the missing source
into an empty directory), a `wg0.conf` still holding `<PLACEHOLDER>` tokens, a
`LOKI_PUSH_URL` whose host is not covered by `AllowedIPs`, or a `VPS_NAME` with an
unsupported character.

---

## 9. Log delivery semantics

- No write-ahead log. Alloy uses a bounded in-memory retry queue; the `alloy_data`
  volume persists read positions and its own data across restarts and redeploys.
- Entries that were read but not yet accepted by Loki are buffered **in memory only**.
  They are lost if the container restarts, is recreated, or if the outage outlasts the
  queue. Nothing is spooled to disk and nothing is replayed from a WAL.
- There is no exactly-once delivery, and no promise of complete request counts. File
  replacement by Dokploy's access-log cleanup can also produce duplicates or gaps;
  treat the stream as evidence, not an accounting ledger.
- Container logs are bounded: `json-file` with `max-size: 10m`, `max-file: 3` on every
  service. Rotation of container stdout is separate from Loki retention.

---

## 10. Metrics semantics

The namespace change is not free: anything that reads network state from `/proc` or
`/sys` would describe the container namespace instead of the host. The stack handles
that explicitly.

| Signal | Source | Status |
| --- | --- | --- |
| Host CPU, memory, disk, filesystem | host-mounted `/host/proc`, `/host/sys`, `/rootfs` | Unchanged. These are not namespace-scoped. |
| Host NIC counters | `vpnctl hostnet-loop` reads `/host/proc/1/net/dev` (host PID 1's namespace) and writes a textfile for node_exporter | Exposed as `node_network_*{source="hostnet"}`. |
| node_exporter `netdev`, `netclass`, `netstat`, `sockstat`, and the other namespace-scoped collectors | disabled in `docker-compose.yml` | Do not re-enable them: they would report `lo`/`wg0` as if they were host NICs. |
| Per-container network | cAdvisor `container_network_*` | The three collectors' own series describe the shared VPN namespace, not the host. |
| cAdvisor `id="/"` network series | cAdvisor | Namespace-scoped for this stack, not host totals. Use `source="hostnet"` for host NICs. |

`hostnet_metrics_available 0` means the textfile helper could not read
`/host/proc/1/net/dev`: the kernel or an AppArmor profile denied it. In that case the
host NIC counters are **absent**, never wrong. Do not "fix" it by re-enabling the
`netdev` collector; fix the read permission or accept the gap. Alongside it,
`hostnet_last_read_timestamp_seconds` shows when the last attempt happened, so you can
alert on `hostnet_metrics_available == 0` or a stale timestamp.

---

## 11. Pilot checklist (user-run)

Short, checkbox style. None of these were executed here; the local suite is static and
unit level only.

Before and after the first deployment:

- [ ] **Public egress before/after**, from an unrelated application container:
      `docker exec <app-container> curl -sS https://ifconfig.me` (or
      `getent hosts ifconfig.me` if `curl` is not in the image). The answer must not
      change, and must not be a tunnel address.
- [ ] **Host default route** on the VPS host before/after: `ip route show default`
      must be identical.
- [ ] **Host DNS** on the VPS host before/after: `cat /etc/resolv.conf` must be
      identical (no `resolvconf` rewrite, no `wg-quick` hook).
- [ ] **Unrelated application container** still reachable from the internet on its
      own port.
- [ ] **Metrics before/after** a VPN disruption: `container_*` and host CPU/memory/disk
      series continue; `node_network_*{source="hostnet"}` keeps advancing;
      `hostnet_metrics_available` stays `1`.
- [ ] **Log flow before/after**: `{job="traefik", vps="<name>"}` receives new entries,
      stops during a deliberate disruption, and resumes afterwards.
- [ ] **Restart/recreate** recovery: `scripts/vpn-redeploy.sh --check` exits 0, a
      forced `vpn` recreate is repaired by `scripts/vpn-redeploy.sh`, and `vpnctl
      verify` passes again.
- [ ] **Removal** (section 12) leaves the host, Traefik, other VPSs and the developer
      VPN unaffected.

Mark every item you did not run as unproven: this repository's tests could not prove
any of them.

---

## 12. Removal

1. Remove this project only. From the directory Dokploy uses for the app (or use
   Dokploy's own Delete action, which runs the project teardown):

   ```bash
   cd /etc/dokploy/compose/<app>/code
   docker compose -p <app> down
   ```

   The project name must match; check it with `docker compose ls` if unsure. Do not
   add `-v` unless you also want to delete the `alloy_data` volume, which holds
   Alloy's read positions: without it, a later redeploy re-reads the current log
   rotation, and everything older is gone. The `node_exporter_textfile` volume can be
   dropped freely.
2. Delete the three Dokploy File Mounts (`wg0.conf`, `vpnctl`, `config.alloy`) and the
   `VPS_NAME` / `LOKI_PUSH_URL` environment values from the service.
3. Revoke the peer in SCM. This is a **human step**, not automated here: remove the
   name from `WG_PEERS`, redeploy the central VPN project, and delete the peer's
   stored key directory if you want the key destroyed rather than reused
   (`docker exec monitoring-wireguard rm -rf /config/peer_<name>`, then redeploy).
   The central runbook documents the exact commands.
4. Confirm nothing else changed: other VPSs keep monitoring, the developer VPN and the
   hub's host networking keep working, and unrelated applications on this VPS keep
   their public egress.

What this stack never touched, and therefore needs no cleanup: host network
interfaces, host routes, host DNS, host sysctls, host firewall rules, Traefik
configuration or certificates, and any other Docker network or container.

---

## 13. Limitations

- **Nothing here was deployed.** No VPS was contacted; every runtime step is pending a
  separately authorized deployment.
- **The repository suite is static/unit; one local sandbox run was made.** A
  separate, user-authorized Docker Desktop sandbox (fake keys, fake hub, no published
  ports, dedicated project, torn down afterwards) exercised the real container path:
  `vpn` became healthy with a real `wg0`, the guard applied, no public egress existed,
  `node_exporter` ran in the shared namespace with `source="hostnet"` counters, a
  VPN-only recreate was detected as stale and repaired, and an unrelated container was
  untouched. It cannot prove the VPS/hub path: no real peer, no handshake, no Dokploy,
  no provider firewall, no Prometheus/Loki. Those remain the pilot items in section 11.
- **The tunnel depends on the host kernel module.** The client image contains no
  userspace WireGuard implementation. If `ip link add dev wg0 type wireguard` fails,
  the stack restart-loops by design rather than falling back.
- **`WG_CONFIG_BASE64` is not a secret.** It is an opt-in fallback, and base64 is NOT encryption:
  `docker inspect`, the Dokploy UI and any local Docker administrator can
  read it. Use the File Mount. Supply exactly one input; supplying both is rejected as
  ambiguous.
- **Isolation is network scoping.** A privileged cAdvisor already has broad host read
  access, so this design limits where monitoring traffic goes, not what a compromised
  collector could read.
- **Provider firewall rules and peer revocation are manual.** No script here changes
  them.
