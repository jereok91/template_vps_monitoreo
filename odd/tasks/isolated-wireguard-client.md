# Isolated WireGuard client for the VPS monitoring template

Deliverable: a client-side WireGuard integration for this template where only the
monitoring collectors use the tunnel, the host network namespace is untouched, and
the operator gets a deterministic Dokploy sequence plus tests. No deployment, no SCM
edit, no commit.

## Specs

- **S1 — Isolated ownership.** "Add a dedicated client VPN service with its own network namespace. Do NOT use network_mode: host, mount the host network namespace, install a host wg0, modify host routes/DNS/sysctls/firewall, or give the VPN service a Docker socket."
- **S2 — Tunnel-only collectors.** "Make Alloy, Node Exporter, and cAdvisor reachable through that isolated tunnel. Sharing the VPN service's network namespace through Compose service network mode is a suitable starting point, not by merely attaching all services to the same Docker bridge." and "Remove public exporter port publications for the VPN deployment. Prometheus must reach the exporters directly through the peer tunnel address."
- **S3 — Minimum capability.** "Use a maintained, deliberately pinned WireGuard client image ... Apply the minimum network capability required in that namespace; do not copy cAdvisor's existing privileged requirement to the VPN service or Alloy. Retain necessary cAdvisor host mounts." and "Document that cAdvisor's existing host privileges mean this is network scoping, not an absolute security boundary."
- **S4 — Configuration delivery.** "Accept one standard WireGuard client configuration generated for that specific VPS. Prefer a protected read-only file/secret mounted through Dokploy ... Make file input the documented default and reject ambiguous simultaneous inputs. ... Base64 is NOT encryption."
- **S5 — Routing scope.** "Preserve the supplied peer address, keys, central endpoint and keepalive. Validate that the supplied routing stays limited to the intended central monitoring address; do not accept default-route tunneling silently. Treat optional DNS settings and wg-quick hooks carefully: do not change host DNS or execute unexpected host-level commands."
- **S6 — Traffic and failure behaviour.** "Allow only the intended monitoring traffic over the tunnel: Alloy pushes to central Loki; central Prometheus pulls the two exporters. Block unintended peer-to-peer access and other inbound tunnel ports, while allowing necessary replies. Implement the applicable client guard inside the isolated network namespace."
- **S7 — Readiness vs connectivity.** "Separate readiness from connectivity claims. A created container does not mean wg0 exists; a configured interface does not prove a recent handshake."
- **S8 — No silent fallback, safe recovery.** "Prevent monitoring traffic from silently falling back to public delivery when the tunnel is absent. ... Provide and test a safe repeatable restart/redeploy procedure that reattaches dependent collectors when necessary."
- **S9 — Logs.** "Preserve bounded Docker log rotation and Alloy's existing persistent positions/data. Do not add unlimited disk spooling or claim exactly-once delivery. Document loss/retry behaviour when Loki is unavailable."
- **S10 — Metrics and Traefik.** "Keep host CPU, memory, filesystem and container metrics meaningful. ... Do not label VPN-container interface statistics as whole-host network statistics." "Preserve Alloy's Traefik file source, stream labels, and read-only directory mount. Keep persistent position data." and "Document the correct Dokploy config-file mount versus the repository-local mount."
- **S11 — Documentation.** "Include an end-to-end operator sequence" (enrol, export, import, identity/URL, provider firewall, deploy, verify, restart, remove) and "Provide a short user-run pilot checklist for remaining integration proof, including unchanged public egress/default route/DNS for unrelated applications and metrics/log flow before and after VPN disruption."
- **S12 — Verification.** "Use deterministic local tests with temporary fixtures, fake keys and mocked network commands. ... Never invoke real host iptables, create real interfaces, contact deployed servers, or start production services. ... Report static/unit checks separately from actual Docker integration checks."
- **S13 — Delivery constraints.** "Do not modify SCM or deploy anything." "Do not commit, push, deploy, or change servers without separate authorization."

## Tasks

| ID  | Spec | Route | Description | Commit |
| --- | ---- | ----- | ----------- | ------ |
| T1  | S1-S13 | inline | ODD document and plan | not committed (delivery constraint S13) |
| T2  | S4, S5, S12 | inline | Failing config/validation tests for `files/vpnctl`, RED observed | not committed |
| T3  | S4-S9, S12 | inline | `files/vpnctl`: input resolution, strict client-config validation, namespace setup, guard, readiness, status/verify, hostnet metrics | not committed |
| T4  | S6-S10, S12 | inline | Stubbed setup/guard/hostnet tests, RED then GREEN | not committed |
| T5  | S1-S3, S9, S10 | inline | `docker-compose.yml`, `env.example`, `.gitignore` | not committed |
| T6  | S8, S12 | inline | `scripts/vpn-redeploy.sh` with `--check` and contract test | not committed |
| T7  | S11 | inline | `README.md`, `docs/vpn-dokploy.md`, fake example client config | not committed |
| T8  | S12, S13 | inline | Full deterministic suite, static/unit report | not committed |

### Commit slices (branch `feat/isolated-wireguard-client`)

| Slice | Contents | Why this boundary |
| --- | --- | --- |
| 1 — `feat(vpn)` | `files/vpnctl` (config validation + `check-config` + argument guard), `tests/lib.sh`, `tests/run.sh`, `tests/test_vpnctl_config.sh` | The validator and its only contract; reviewed first. |
| 2 — `test(vpn)` | `tests/test_vpnctl_config.sh` (unexpected-argument regression) | Pins the real defect the first review found. |
| 3 — `feat(vpn)` | `files/vpnctl` (interface, guard, readiness, supervisor, IPv6 lockdown), `tests/test_vpnctl_setup.sh` | Everything the container does at start, with the suite that drives its exact command sequence. Reviewed second. |
| 4 — `fix(vpn)` | `files/vpnctl`, `tests/test_vpnctl_setup.sh` | Closes the namespace on a failed start and restores the default route on TERM (the regression the slice-3 validator caught). |
| 5 — `test(vpn)` | `tests/test_vpnctl_hostnet.sh` | Host NIC counters, the one replacement metric path. |
| 6 — `feat(compose)` | `docker-compose.yml`, `env.example`, `.gitignore`, `tests/test_compose_contract.sh` | Deployment shape and its static contract. |
| 7 — `feat(vpn)` | `scripts/vpn-redeploy.sh`, `tests/test_redeploy_contract.sh` | Recovery procedure and its stubbed contract. |
| 8 — `docs` | `README.md`, `docs/vpn-dokploy.md`, `files/wg0.conf.example`, `tests/test_docs_contract.sh`, this document | Operator-facing contract; the docs test keeps the guide aligned with the code. |

Each slice is green when it lands (`bash tests/run.sh`).

Native review so far (risk/readability/reliability; risk/resilience/reliability):

- Slice 1 was approved after one bounded correction (22 diff lines): the refuter
  confirmed that unexpected subcommand arguments were silently ignored and that
  the slice advertised subcommands it did not implement yet. Both are fixed, and
  the argument case is pinned in slice 2.
- Slice 3's refuter confirmed five findings: IPv6 was outside the guard, the
  healthcheck and supervisor verified only two of the ten allow rules, and a
  same-namespace restart could not recover from a half-built guard or a deleted
  default route. The bounded correction (118 diff lines) addressed all five and
  was confirmed by the targeted validator, which then rejected it for one
  regression it introduced: `guard_reset` left the namespace open when startup
  failed. The authority is terminal (`escalated`), so slice 4 fixes that
  regression (close both families on failure, restore the default route on TERM)
  with its own assertions as ordinary follow-up work.
- Slices 5-8 are not natively reviewed. Their evidence is the deterministic
  suite; no delivery gate was consumed by the open review.

Delivery is eight commits on the feature branch. No push, no PR and no
deployment (S13).

## Log

### L1 — original request (verbatim, user)

> Implement an isolated WireGuard client for the VPS monitoring template
>
> Work locally in `/Users/jeremy/Desktop/Project/template_vps_monitoreo`. Inspect the current checkout and applicable repository instructions before making changes. Implement the client-side monitoring VPN integration described below, with tests and a clear Dokploy setup guide. Do not modify SCM or deploy anything.
>
> ## Objective
>
> Run a WireGuard client within this template's Docker Compose, with the tunnel isolated from the host and unrelated application containers. Only the monitoring collectors should use it. Preserve the VPS applications' normal Internet access, host routes, DNS, and Dokploy/Traefik behavior.
>
> The user will run the actual VPS pilot. Your deliverable is a locally implemented, verified configuration plus explicit pilot instructions, not a claim of live connectivity.
>
> ## Existing context
>
> The template currently runs Node Exporter, cAdvisor, and Grafana Alloy. There is no VPN client in it. Exporters currently publish host ports 9100 and 8080. Alloy reads the existing Traefik access-log directory through a read-only bind and stores its positions/data in a named volume.
>
> The separate central repository SCM already manages a WireGuard hub, Prometheus, Grafana, Loki, and a push-only Loki proxy. It enrolls peers through WG_PEERS and exports one client configuration per VPS using scripts/vpn/peer.sh show <name>. There is no web UI yet. A future UI must be able to deliver an equivalent standard client configuration without requiring this template to be redesigned.
>
> Current SCM example: hub tunnel address 10.77.0.1; one unique peer tunnel address per VPS; client AllowedIPs restricted to the hub address; central public UDP endpoint; private Loki push URL http://10.77.0.1:3100/loki/api/v1/push. These are examples, not addresses to hardcode. Prometheus scrapes each peer tunnel address on 9100 and 8080. The central currently has a separate host-network VPN project and its own host firewall guard; this task does not move or replace the central VPN.
>
> ## Required implementation
>
> ### 1. Isolated network ownership
>
> Add a dedicated client VPN service with its own network namespace. Do NOT use network_mode: host, mount the host network namespace, install a host wg0, modify host routes/DNS/sysctls/firewall, or give the VPN service a Docker socket.
>
> Make Alloy, Node Exporter, and cAdvisor reachable through that isolated tunnel. Sharing the VPN service's network namespace through Compose service network mode is a suitable starting point; merely attaching all services to the same Docker bridge is not sufficient. Confirm support in Dokploy's actual Docker Compose deployment mode; do not assume Swarm stack behavior is interchangeable.
>
> Remove public exporter port publications for the VPN deployment. Prometheus must reach the exporters directly through the peer tunnel address. The collectors must bind appropriately inside the shared namespace. Keep any management endpoints private. Unrelated applications must not join this namespace or depend on the VPN.
>
> Use a maintained, deliberately pinned WireGuard client image after checking its official documentation. Apply the minimum network capability required in that namespace; do not copy cAdvisor's existing privileged requirement to the VPN service or Alloy. Retain necessary cAdvisor host mounts unless evidence requires a documented adjustment. Document that cAdvisor's existing host privileges mean this is network scoping, not an absolute security boundary against a compromised privileged collector.
>
> ### 2. Configuration delivery per VPS
>
> Accept one standard WireGuard client configuration generated for that specific VPS. Prefer a protected read-only file/secret mounted through Dokploy, not credentials committed to Git or embedded in the Compose file. Explain exactly how the user exports it centrally and imports it through Dokploy's file-mount/secret mechanism, including the image's expected path and filename. Never ask the user to paste a real private key into chat.
>
> If Dokploy constraints require an environment-based fallback, implement it explicitly: for example a sensitive base64-encoded config decoded at startup into a restricted, nonlogged file. Base64 is NOT encryption. Do not claim environment variables are secret from Docker administrators or inspection. Make file input the documented default and reject ambiguous simultaneous inputs. No real credentials in examples, fixtures, build layers, or CI output.
>
> Preserve the supplied peer address, keys, central endpoint and keepalive. Validate that the supplied routing stays limited to the intended central monitoring address; do not accept default-route tunneling silently. Treat optional DNS settings and wg-quick hooks carefully: do not change host DNS or execute unexpected host-level commands. Explain how generated DNS settings are handled inside the isolated namespace without breaking startup or endpoint resolution.
>
> ### 3. Private traffic and failure behavior
>
> Allow only the intended monitoring traffic over the tunnel: Alloy pushes to central Loki; central Prometheus pulls the two exporters. Block unintended peer-to-peer access and other inbound tunnel ports, while allowing necessary replies. Implement the applicable client guard inside the isolated network namespace, not by blindly running SCM's host DOCKER-USER firewall script. That script assumes a different network topology and cannot simply be reused unchanged.
>
> Separate readiness from connectivity claims. A created container does not mean wg0 exists; a configured interface does not prove a recent handshake. Establish the required interface/address/routes and restrictive rules before marking the VPN ready. Describe what happens if the central is offline.
>
> Prevent monitoring traffic from silently falling back to public delivery when the tunnel is absent. Account for crash, tunnel teardown, client restart, and container recreation. Compose depends_on readiness alone is not a runtime kill switch and does not automatically repair shared network namespace attachments after force-recreation. Provide and test a safe repeatable restart/redeploy procedure that reattaches dependent collectors when necessary. Unrelated applications must remain untouched throughout.
>
> Preserve bounded Docker log rotation and Alloy's existing persistent positions/data. Do not add unlimited disk spooling or claim exactly-once delivery. Document loss/retry behavior when Loki is unavailable without changing unrelated log-pipeline behavior.
>
> ### 4. Preserve metrics and Traefik integration
>
> Keep host CPU, memory, filesystem and container metrics meaningful. Verify the effect of the new network namespace on Node Exporter's network-related collectors and cAdvisor. Do not label VPN-container interface statistics as whole-host network statistics. If accurate host network metrics require a separate narrow read-only collection mechanism, explain and implement the minimum justified approach without moving the VPN into the host namespace or silently losing existing metrics.
>
> Preserve Alloy's Traefik file source, stream labels, and read-only directory mount. Keep persistent position data. Do not add Traefik volumes or manually modify the Dokploy-managed Traefik container. Document the correct Dokploy config-file mount versus the repository-local mount. Do not relax certificate/private-key permissions in the shared Traefik directory to make Alloy work.
>
> ## Documentation and compatibility
>
> Update docker-compose.yml, env.example, README, and narrowly scoped new configuration/bootstrap/test files as needed. Preserve runtime secrets in ignored/protected storage. Follow the existing artifact language conventions; otherwise use English.
>
> Include an end-to-end operator sequence:
> 1. Enroll one peer in SCM and securely export its configuration.
> 2. Import it into the new VPS's Dokploy Compose service.
> 3. Set the VPS identity and private Loki push URL.
> 4. Configure provider firewall rules for the selected UDP transport, explicitly distinguishing stateful outbound/return traffic from a fixed inbound client listen port. Never open exporter/Loki TCP ports publicly as a shortcut.
> 5. Deploy the collector stack through Dokploy.
> 6. Confirm handshake, central-to-peer exporter access, and Alloy-to-Loki ingestion.
> 7. Restart/recreate the VPN safely and verify recovery.
> 8. Remove this client's stack/config safely without affecting application traffic or other peers.
>
> List any minimal SCM prerequisite, but do not edit SCM. Preserve old monitored VPSs and the developer VPN.
>
> ## Verification
>
> Use deterministic local tests with temporary fixtures, fake keys and mocked network commands. Observe RED before GREEN where meaningful. Never invoke real host iptables, create real interfaces, contact deployed servers, or start production services. Validate Compose using dummy env/config values without printing secrets. Use official documentation to verify image client-mode paths, permissions, capabilities and startup behavior.
>
> Pin tests for:
> - missing/malformed client config fails safely without leaking it;
> - non-default hub/peer addresses work without hardcoded defaults;
> - namespace sharing and absence of host network mode/public exporter ports;
> - readiness only after intended address/routes/guard exist;
> - intended traffic allowed and unintended tunnel access denied;
> - tunnel-down behavior cannot send logs publicly;
> - recreation/recovery procedure does not retain stale network namespace dependencies;
> - existing Alloy labels, state persistence, Traefik directory mount and bounded logs remain intact;
> - host metric semantics are preserved or explicitly identified with evidence, never silently substituted.
>
> Tests that only mock Docker returning success do not prove routing or namespace recreation. Report static/unit checks separately from actual Docker integration checks. Any live sandbox/container integration test requires explicit permission and must not mutate the real host network. Provide a short user-run pilot checklist for remaining integration proof, including unchanged public egress/default route/DNS for unrelated applications and metrics/log flow before and after VPN disruption.
>
> ## Final report
>
> Summarize implementation, exact changed files, observed tests and limitations, and Dokploy's required per-VPS inputs. Clearly state which checks were not run. Do not commit, push, deploy, or change servers without separate authorization. If a consequential product decision cannot be resolved from these requirements, ask one focused question before making that decision.
>
> ayudame a implementar

### L2 — repository evidence gathered (read-only)

- `docker-compose.yml` (pre-change): node_exporter publishes `9100:9100`, cAdvisor publishes
  `8080:8080`, Alloy mounts `./files/config.alloy` and `/etc/dokploy/traefik/dynamic:ro`, uses
  `alloy_data` named volume, runs as `473:473`, drops ALL capabilities, bounded json-file logs.
- `files/config.alloy`: `loki.source.file` on `/var/log/traefik/access.log`, labels
  `job="traefik"` + `vps=sys.env("VPS_NAME")`, pushes to `sys.env("LOKI_PUSH_URL")`; no WAL.
- SCM `scripts/vpn/peer.sh show <name>` emits a config with `Address = <peer>/24`,
  `ListenPort = 51820`, `DNS = <public resolver>`, `[Peer] PublicKey`, `PresharedKey`,
  `AllowedIPs = 10.77.0.1/32`, `Endpoint = <WG_SERVERURL>:51820`, `PersistentKeepalive = 25`.
  Therefore the accepted format must tolerate a public `DNS` line that is outside AllowedIPs.
- SCM `scripts/vpn/firewall.sh` is a host `DOCKER-USER`/`INPUT` guard for the host-network hub
  and peer roles; it assumes host interfaces (`wg0`, `br-+`) and cannot be reused inside a
  container namespace. Only its *intent* is reused here.
- SCM Prometheus runs on `monitoring-net`; Docker's bridge MASQUERADE rewrites scrape packets to
  the hub tunnel address, which is what the client's WireGuard cryptokey routing
  (`AllowedIPs = <hub>/32`) accepts as inner source.
- Dokploy docs: Compose type "Docker Compose" vs "Stack"; Stack does not support `build` and
  Swarm does not support `network_mode` (moby#33055) → this template documents Compose type
  `Docker Compose` only. Repository-relative mounts are not durable under AutoDeploy; the
  durable location is `<app>/files/` mounted as `../files/...` (Dokploy File Mounts).
- `lscr.io/linuxserver/wireguard` is the image already pinned by SCM
  (`1.0.20260223-r0-ls126`); its Dockerfile installs `wireguard-tools`, `iproute2`, `iptables`,
  `openresolv`; its documented client-mode config path is `/config/wg0.conf`. It contains no
  userspace implementation, so the host kernel must provide the `wireguard` module.
- Local environment: macOS + Docker Desktop; no wireguard kernel module and no permission to run
  container integration tests → only static/unit evidence (see T8).

### L3 — decisions

- **D1** The pinned linuxserver image is used, but with `entrypoint` overridden to
  `/bin/sh /opt/vpn/vpnctl`. Reason: wg-quick executes config hooks, applies `DNS` to
  `/etc/resolv.conf`, and installs whatever routes `AllowedIPs` names (including a default route).
  The task forbids silent default-route tunnelling and unexpected commands, so the interface,
  routes, guard and readiness are created explicitly by `vpnctl` from a validated, sanitized
  config. The image's documented client path `/config/wg0.conf` is preserved as the mount point.
- **D2** `network_mode: "service:vpn"` for the three collectors plus a dedicated `vpn_egress`
  bridge attached to the VPN service only (WireGuard still needs one path to the hub's public
  UDP endpoint). The bridge is not the isolation mechanism: isolation is the private netns plus
  default-DROP iptables plus the removal of the default route after the endpoint host route is
  installed.
- **D3** `AllowedIPs` must be IPv4, must not be a default route, must be at least as specific as
  `VPN_ALLOWED_IPV4_MIN_PREFIX` (default `/24`), and must cover the Loki push host. The peer
  `Address` prefix is preserved in the report but applied as a host route (`/32`) so the
  interface installs no connected subnet route towards other peers.
- **D4** `DNS` lines are validated for shape and ignored (never applied, host resolver untouched);
  `PreUp`/`PostUp`/`PreDown`/`PostDown`/`Table`/`SaveConfig` are rejected. Endpoint hostnames are
  resolved once by `wg setconf` before lockdown (Docker DNS is still reachable then); the
  resolved address is read back from `wg show` and used by the guard. `VPN_ENDPOINT_IP` is the
  explicit, documented alternative when the operator wants no resolution step at all.
- **D5** Host NIC counters: inside the isolated namespace sysfs and `/proc/net` are
  namespace-scoped, so node_exporter's network collectors would report `lo`/`wg0` as if they were
  host interfaces. Those collectors are disabled and a narrow read-only helper in the VPN
  container reads `/host/proc/1/net/dev` (host PID 1's netns) and feeds node_exporter's textfile
  collector. If that read is denied, `hostnet_metrics_available 0` is exported instead of wrong
  data. Host CPU/memory/disk/filesystem metrics are untouched because they come from the
  host-mounted `/host/proc` and `/rootfs`.
- **D6** `files/vpnctl` is mounted read-only from `./files/` (repository) or `../files/`
  (Dokploy). Consequence of D1 and of not requiring a custom image build: the deployed copy is a
  second copy that must be pasted into the Dokploy File Mount; this is documented next to the
  existing `config.alloy` two-copy note.

### L4 — verification evidence

Static/unit only: no Docker container was started, no interface was created, no host
firewall was touched and no server was contacted.

- `bash tests/run.sh` → **6/6 suites, 457 assertions, exit 0** (17 s):
  `test_vpnctl_config.sh` 122, `test_vpnctl_setup.sh` 97, `test_vpnctl_hostnet.sh` 64,
  `test_compose_contract.sh` 82, `test_redeploy_contract.sh` 20,
  `test_docs_contract.sh` 72.
- RED observed before GREEN: the config suite against a checkout without `files/vpnctl`
  reported 8 passed / 73 failed; the worker recorded RED for the base64 ambiguity and
  the hostnet metric shape before implementing them.
- Syntax: `sh -n files/vpnctl` and `bash -n` on every script.
- Secret hygiene: no 44-character key-shaped material outside `tests/` and
  `files/wg0.conf.example` (fake, all-letter filler); `.env` and `files/wg0.conf` are
  git-ignored; every failure path is asserted to print the field/directive only.
- Compose differential against `HEAD:docker-compose.yml` (rendered with dummy env):
  images, users, `cap_drop`, cadvisor host mounts and alloy mounts are unchanged;
  the only differences are the intended ones — published ports removed,
  `network_mode: "service:vpn"` added, bounded logs added to the two exporters, the
  `node_exporter_textfile` volume added, and the new `vpn` service. No `network_mode:
  host`, no Docker socket for `vpn`.
- `files/wg0.conf.example` passes `check-config` with fake keys and is asserted fake by
  the docs contract test.
- Independent verifier: `gentle-ai-verify` was launched read-only and **timed out after
  30 minutes without a report**; it is reported as unavailable and was not retried.
  The parent review covered the guard rule set, `cmd_up` ordering
  (guard → endpoint host route → default-route removal → readiness marker), the
  readiness/connectivity split, and the no-`eval`/quoting discipline.
- Two long blocking invocations of the suite stalled in the tool output layer while the
  suite itself finished in 17 s; the suite was re-run green three times (455, 457, 457
  assertions as the docs test grew).
- **Not run** (requires explicit permission and a Linux host, and must not mutate a real
  host network): container start, real `ip link add ... type wireguard`, netns iptables
  behaviour, real `wg` handshake/hostname resolution, readability of
  `/proc/1/net/dev`, namespace recreation and re-attachment with real containers,
  provider firewall, Prometheus scrape and Loki ingestion, and the host
  egress/route/DNS before-and-after pilot checks. These are the pilot checklist items in
  `docs/vpn-dokploy.md` §11 and are marked unproven there.
- **Local Docker Desktop sandbox (user-authorized, fake keys, fake hub, no published
  ports, dedicated project, torn down afterwards)**: 36 checks, 35 `ok` plus one harness
  false positive disproven separately (`HostConfig.PortBindings {}`, `docker port`
  empty; the only entry in `NetworkSettings.Ports` is the image's `EXPOSE 51820/udp`).
  Proven: `vpn` healthy with a real `wg0`, the `/32` address, the hub route, the endpoint
  `/32` before the default route was deleted, no default route afterwards, the exact
  guard rules (`iptables -C`), gateway and public egress blocked, `node_exporter`
  reachable inside the shared namespace with `source="hostnet"` counters and
  `hostnet_metrics_available 1`, no host port binding on either container, stale
  detection after a VPN-only recreate, redeploy repair, an unrelated container
  untouched, and a clean teardown. Harness defects found and fixed during the run were
  test-side only (iptables `-S` argument order, SIGPIPE under `pipefail`, an
  `EXPOSE`-inflated `NetworkSettings.Ports` length, and one missing fixture file); no
  product code changed for them.
- **Native RDD review**: the original 3-commit candidate returned
  `lens_context_budget_exceeded` (no authority created, nothing half-open). The
  branch was re-sliced into eight green commits and reviewed slice by slice:
  - Slice 1 (validator): **approved** after a bounded correction (22 diff lines)
    that rejected unexpected subcommand arguments and trimmed the usage to what
    the slice implements. The acknowledgement burned that authority; five
    advisory (non-blocking) findings were reported.
  - Slice 3 (runtime, risk/resilience/reliability): the refuter confirmed five
    candidate-caused findings (IPv6 outside the guard; healthcheck and supervisor
    verifying only two of ten allow rules; no same-namespace recovery from a
    half-built guard or a deleted default route). The bounded correction (118 diff
    lines: IPv6 lockdown, full `guard_verify_for` in healthcheck and supervisor,
    `guard_reset`, default-route restore) fixed all five; the targeted validator
    confirmed every original criterion and rejected the correction for one
    regression it introduced (`guard_reset` left the namespace open on a failed
    start). The authority is terminal (`escalated`), so commit 4 fixes that
    regression with assertions on every failure path and on TERM.
  - Slices 2, 4-8 were not natively reviewed; their evidence is the deterministic
    suite (466 assertions) plus the local Docker Desktop sandbox re-run against
    the corrected runtime (healthy, IPv6 DROP policies, healthcheck fails when an
    allow rule is removed, clean teardown).
