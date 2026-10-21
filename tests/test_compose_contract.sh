#!/usr/bin/env bash
#
# Static contract for docker-compose.yml, env.example, .gitignore and the Alloy
# config. It renders the Compose model with `docker compose config` (client-side
# only: no daemon, no container, no network) and asserts the isolation, metric and
# log invariants this template promises.
#
#   bash tests/test_compose_contract.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE="${REPO_ROOT}/docker-compose.yml"

# shellcheck source=tests/lib.sh
. "${REPO_ROOT}/tests/lib.sh"
mkwork compose

if ! command -v docker >/dev/null 2>&1; then
  printf 'SKIP: docker CLI not available; cannot render the Compose model\n'
  exit 0
fi

# Dummy values only: the rendered model is never printed, so no secret can leak.
cat >"${WORK}/dummy.env" <<'ENV'
VPS_NAME=contract-test
LOKI_PUSH_URL=http://10.77.0.1:3100/loki/api/v1/push
ENV

set +e
docker compose --env-file "${WORK}/dummy.env" -f "${COMPOSE}" config --format json >"${WORK}/model.json" 2>"${WORK}/compose.err"
compose_rc=$?
set -e
if [ "${compose_rc}" -ne 0 ]; then
  bad "compose model renders (docker compose config failed)"
  sed -n '1,5p' "${WORK}/compose.err" >&2
  finish
  exit 1
fi
ok "compose model renders with dummy environment values"

python3 - "${WORK}/model.json" <<'PY' >"${WORK}/facts"
import json
import sys

model = json.load(open(sys.argv[1]))
services = model["services"]
volumes = model.get("volumes", {})
networks = model.get("networks", {})

ok = []
bad = []


def check(label, condition):
    (ok if condition else bad).append(label)


def svc(name):
    return services[name]


def bind(service, target):
    for mount in svc(service).get("volumes", []):
        if mount.get("target") == target:
            return mount
    return None


def has_cmd_flag(service, flag):
    command = svc(service).get("command") or []
    return any(isinstance(part, str) and part.startswith(flag) for part in command)


# --- service inventory and namespace ownership ------------------------------
check("exactly vpn/node_exporter/cadvisor/alloy are defined",
      sorted(services) == ["alloy", "cadvisor", "node_exporter", "vpn"])
check("no service uses the host network namespace",
      all(s.get("network_mode") != "host" for s in services.values()))
check("no service publishes a port",
      all("ports" not in s for s in services.values()))
check("vpn has no network_mode override (own namespace)",
      "network_mode" not in svc("vpn"))
check("vpn is attached only to the dedicated vpn_egress bridge",
      list(svc("vpn").get("networks", {}).keys()) == ["vpn_egress"])
check("vpn_egress is a bridge network",
      networks.get("vpn_egress", {}).get("driver") == "bridge")
for collector in ("node_exporter", "cadvisor", "alloy"):
    check(f"{collector} shares the vpn namespace",
          svc(collector).get("network_mode") == "service:vpn")
    check(f"{collector} waits for a healthy vpn",
          svc(collector).get("depends_on", {}).get("vpn", {}).get("condition") == "service_healthy")

# --- vpn service shape ------------------------------------------------------
check("vpn image is pinned to the reviewed linuxserver tag",
      svc("vpn").get("image") == "lscr.io/linuxserver/wireguard:1.0.20260223-r0-ls126")
check("vpn entrypoint is the reviewed vpnctl script",
      svc("vpn").get("entrypoint") == ["/bin/sh", "/opt/vpn/vpnctl"])
check("vpn runs the up subcommand", svc("vpn").get("command") == ["up"])
check("vpn drops ALL capabilities", svc("vpn").get("cap_drop") == ["ALL"])
check("vpn adds only NET_ADMIN", svc("vpn").get("cap_add") == ["NET_ADMIN"])
check("vpn is not privileged", not svc("vpn").get("privileged"))
check("vpn sets no-new-privileges",
      "no-new-privileges:true" in (svc("vpn").get("security_opt") or []))
check("vpn has a readiness healthcheck",
      svc("vpn").get("healthcheck", {}).get("test") == [
          "CMD", "/bin/sh", "/opt/vpn/vpnctl", "healthcheck"])
check("vpn restarts unless stopped",
      svc("vpn").get("restart") == "unless-stopped")
check("vpn mounts the vpnctl script read-only",
      (bind("vpn", "/opt/vpn/vpnctl") or {}).get("read_only") is True and
      str((bind("vpn", "/opt/vpn/vpnctl") or {}).get("source", "")).endswith("files/vpnctl"))
check("vpn mounts the client config read-only at the image's documented path",
      (bind("vpn", "/config/wg0.conf") or {}).get("read_only") is True and
      str((bind("vpn", "/config/wg0.conf") or {}).get("source", "")).endswith("files/wg0.conf"))
check("vpn mounts host procfs read-only for host NIC counters",
      (bind("vpn", "/host/proc") or {}).get("read_only") is True)
check("vpn never mounts /var/run or a docker socket",
      not any(m.get("target", "").startswith("/var/run") or "docker.sock" in str(m.get("source", ""))
              for m in svc("vpn").get("volumes", [])))
check("vpn keeps runtime secrets on tmpfs",
      any(str(t).startswith("/run/vpn:") for t in svc("vpn").get("tmpfs") or []))

# --- node_exporter: host metrics preserved, namespace metrics disabled ------
check("node_exporter keeps the host procfs mount",
      (bind("node_exporter", "/host/proc") or {}).get("read_only") is True)
check("node_exporter keeps the host sysfs mount",
      (bind("node_exporter", "/host/sys") or {}).get("read_only") is True)
check("node_exporter keeps the host rootfs mount",
      (bind("node_exporter", "/rootfs") or {}).get("read_only") is True)
check("node_exporter reads host NIC counters from the textfile volume",
      (bind("node_exporter", "/var/lib/node_exporter/textfile") or {}).get("read_only") is True)
check("node_exporter listens only inside the namespace",
      has_cmd_flag("node_exporter", "--web.listen-address=0.0.0.0:9100"))
check("node_exporter enables the textfile collector",
      has_cmd_flag("node_exporter", "--collector.textfile.directory=/var/lib/node_exporter/textfile"))
for collector in ("arp", "bonding", "conntrack", "ethtool", "infiniband", "ipvs",
                  "lnstat", "netclass", "netdev", "netstat", "network_route", "nfs",
                  "nfsd", "qdisc", "sockstat", "softnet", "tcpstat", "udp_queues",
                  "wifi", "xfrm"):
    check(f"node_exporter disables the namespace-scoped {collector} collector",
          has_cmd_flag("node_exporter", f"--no-collector.{collector}"))
check("node_exporter does not re-enable netdev",
      not has_cmd_flag("node_exporter", "--collector.netdev"))

# --- cadvisor: host access retained, endpoint private -----------------------
check("cadvisor keeps its privileged host access",
      svc("cadvisor").get("privileged") is True)
for target in ("/rootfs", "/var/run", "/sys", "/var/lib/docker", "/dev/disk"):
    check(f"cadvisor keeps its {target} mount", bind("cadvisor", target) is not None)
check("cadvisor keeps /dev/kmsg",
      any("/dev/kmsg" in str(device) for device in svc("cadvisor").get("devices") or []))
check("cadvisor binds inside the namespace",
      has_cmd_flag("cadvisor", "--listen_ip=0.0.0.0"))
check("cadvisor uses the reviewed port",
      has_cmd_flag("cadvisor", "--port=8080"))

# --- alloy: Traefik source, labels, persistence, private endpoint -----------
check("alloy runs as the image's unprivileged user",
      svc("alloy").get("user") == "473:473")
check("alloy drops ALL capabilities", svc("alloy").get("cap_drop") == ["ALL"])
check("alloy sets no-new-privileges",
      "no-new-privileges:true" in (svc("alloy").get("security_opt") or []))
check("alloy mounts config.alloy read-only",
      (bind("alloy", "/etc/alloy/config.alloy") or {}).get("read_only") is True and
      str((bind("alloy", "/etc/alloy/config.alloy") or {}).get("source", "")).endswith("files/config.alloy"))
check("alloy mounts the Dokploy Traefik log directory read-only",
      (bind("alloy", "/var/log/traefik") or {}).get("read_only") is True and
      (bind("alloy", "/var/log/traefik") or {}).get("source") == "/etc/dokploy/traefik/dynamic")
check("alloy keeps its persistent positions/data volume",
      (bind("alloy", "/var/lib/alloy/data") or {}).get("type") == "volume" and
      (bind("alloy", "/var/lib/alloy/data") or {}).get("source") == "alloy_data")
check("alloy has no extra Traefik volume",
      len(svc("alloy").get("volumes", [])) == 3)

# --- bounded logs and declared volumes ------------------------------------
check("alloy_data and node_exporter_textfile volumes are declared",
      "alloy_data" in volumes and "node_exporter_textfile" in volumes)
for name, service in services.items():
    logging = service.get("logging") or {}
    options = logging.get("options") or {}
    check(f"{name} uses bounded json-file logs",
          logging.get("driver") == "json-file" and
          options.get("max-size") == "10m" and options.get("max-file") == "3")

for line in ok:
    print(f"ok: {line}")
for line in bad:
    print(f"FAIL: {line}")
sys.exit(0 if not bad else 1)
PY
python_rc=$?

while IFS= read -r line; do
  case "${line}" in
    "ok: "*) PASS=$((PASS + 1)); printf '  %s\n' "${line}" ;;
    "FAIL: "*) FAIL=$((FAIL + 1)); printf '  %s\n' "${line}" ;;
  esac
done <"${WORK}/facts"
[ "${python_rc}" = 0 ] || true

# ---------------------------------------------------------------------------
# Files that carry the pipeline semantics.
# ---------------------------------------------------------------------------
ALLOY="${REPO_ROOT}/files/config.alloy"
if grep -qF '__path__ = "/var/log/traefik/access.log"' "${ALLOY}" &&
  grep -qF 'job      = "traefik"' "${ALLOY}" &&
  grep -qF 'vps      = sys.env("VPS_NAME")' "${ALLOY}" &&
  grep -qF 'url = sys.env("LOKI_PUSH_URL")' "${ALLOY}"; then
  ok "alloy config keeps the Traefik source, stream labels and Loki endpoint"
else
  bad "alloy config lost the Traefik source, stream labels or Loki endpoint"
fi
if grep -qE '^[[:space:]]*wal[[:space:]]*\{' "${ALLOY}"; then
  bad "alloy config must not add an unbounded write-ahead log"
else
  ok "alloy config keeps bounded in-memory retry (no disk WAL)"
fi

ENV_EXAMPLE="${REPO_ROOT}/env.example"
if grep -q '^VPS_NAME=' "${ENV_EXAMPLE}" && grep -q '^LOKI_PUSH_URL=' "${ENV_EXAMPLE}"; then
  ok "env.example documents the two required variables"
else
  bad "env.example is missing a required variable"
fi
if grep -qE '^WG_CONFIG_BASE64=' "${ENV_EXAMPLE}"; then
  bad "env.example must not pre-set the base64 fallback"
else
  ok "env.example leaves the base64 fallback opt-in"
fi
if grep -qE '[A-Za-z0-9+/]{43}=' "${ENV_EXAMPLE}" "${COMPOSE}"; then
  bad "env.example or docker-compose.yml contains key-shaped material"
else
  ok "env.example and docker-compose.yml contain no key-shaped material"
fi

if grep -qx '.env' "${REPO_ROOT}/.gitignore" && grep -qx 'files/wg0.conf' "${REPO_ROOT}/.gitignore"; then
  ok ".gitignore protects .env and files/wg0.conf"
else
  bad ".gitignore does not protect .env and files/wg0.conf"
fi

if grep -qE '9100:9100|8080:8080' "${COMPOSE}"; then
  bad "docker-compose.yml still publishes exporter ports"
else
  ok "docker-compose.yml publishes no exporter port"
fi

if grep -qF 'WG_CONFIG_PATH' "${COMPOSE}"; then
  ok "the client config mount is overridable for Dokploy (WG_CONFIG_PATH)"
else
  bad "the client config mount is hardcoded; Dokploy cannot point it at ../files"
fi

finish
