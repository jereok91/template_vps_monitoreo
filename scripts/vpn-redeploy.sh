#!/usr/bin/env bash
#
# Recreate the monitoring VPN container and re-attach its dependents.
#
# Why this script exists: node_exporter, cadvisor and alloy run in the VPN
# container's network namespace (`network_mode: "service:vpn"`). Recreating only
# the VPN container gives it a *new* namespace while the collectors keep pointing
# at the old, dead one: they look alive but are unreachable from the hub. Compose
# readiness (`depends_on: service_healthy`) prevents that on a normal `up`, but it
# cannot repair a stale attachment afterwards.
#
#   scripts/vpn-redeploy.sh [--check] [--wait SECONDS] [--project NAME]
#
#   (no flag)   recreate vpn + node_exporter + cadvisor + alloy in one ordered
#               `docker compose up`, wait for the VPN healthcheck, verify the
#               attachments. Unrelated applications and services are untouched.
#   --check     read-only: report whether every collector is attached to the
#               *current* VPN container and whether the VPN is healthy.
#               0 = healthy and attached, 1 = stale/unhealthy, 2 = usage/error.
#
# Environment:
#   COMPOSE_FILE                 compose file (default: ../docker-compose.yml)
#   COMPOSE_PROJECT_NAME         Dokploy project name (passed as `docker compose -p`)
#   VPN_REDEPLOY_WAIT_SECONDS    health wait budget (default 60)
#   VPN_REDEPLOY_POLL_SECONDS    poll interval (default 2)
#
# The tunnel and the guard live inside the namespace, so this script never touches
# host routes, DNS or firewall rules.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPOSE_FILE="${COMPOSE_FILE:-${SCRIPT_DIR}/../docker-compose.yml}"
PROJECT="${COMPOSE_PROJECT_NAME:-}"
WAIT_SECONDS="${VPN_REDEPLOY_WAIT_SECONDS:-60}"
POLL_SECONDS="${VPN_REDEPLOY_POLL_SECONDS:-2}"

# Order matters: the VPN is created first, then the namespace consumers.
SERVICES=(vpn node_exporter cadvisor alloy)
COLLECTORS=(node_exporter cadvisor alloy)

MODE="redeploy"

usage() {
  cat >&2 <<'USAGE'
usage: scripts/vpn-redeploy.sh             # recreate the tunnel and re-attach collectors
       scripts/vpn-redeploy.sh --check     # read-only attachment/health check
       scripts/vpn-redeploy.sh --wait N    # health wait budget in seconds (default 60)
       scripts/vpn-redeploy.sh --project P # Dokploy project name (-p)
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --check) MODE="check"; shift ;;
    --wait)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      WAIT_SECONDS="$2"
      shift 2
      ;;
    --project)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      PROJECT="$2"
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "vpn-redeploy: unknown argument '$1'" >&2; usage; exit 2 ;;
  esac
done

case "${WAIT_SECONDS}" in
  ''|*[!0-9]*) echo "vpn-redeploy: --wait must be a non-negative integer" >&2; exit 2 ;;
esac
case "${POLL_SECONDS}" in
  ''|*[!0-9]*|0*) echo "vpn-redeploy: POLL_SECONDS must be a positive integer" >&2; exit 2 ;;
esac

log() { printf '[vpn-redeploy] %s\n' "$*" >&2; }
fail() { printf '[vpn-redeploy] error: %s\n' "$*" >&2; exit 1; }

compose() {
  if [ -n "${PROJECT}" ]; then
    docker compose -p "${PROJECT}" -f "${COMPOSE_FILE}" "$@"
  else
    docker compose -f "${COMPOSE_FILE}" "$@"
  fi
}

inspect_field() { # <format> <container-id>
  docker inspect -f "$1" "$2" 2>/dev/null
}

service_id() { # <service>
  compose ps -q "$1" 2>/dev/null | head -n 1
}

vpn_health() { # <container-id>
  h="$(inspect_field '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$1" || true)"
  printf '%s' "${h:-unknown}"
}

check_attachments() { # <vpn-container-id>; sets STALE
  STALE=0
  for svc in "${COLLECTORS[@]}"; do
    id="$(service_id "${svc}" || true)"
    if [ -z "${id}" ]; then
      log "${svc}: not running"
      STALE=1
      continue
    fi
    mode="$(inspect_field '{{.HostConfig.NetworkMode}}' "${id}" || true)"
    if [ "${mode}" = "container:${1}" ]; then
      log "${svc}: attached to the current vpn namespace"
    else
      log "${svc}: STALE network mode '${mode:-unknown}' (expected container:${1})"
      STALE=1
    fi
  done
  return 0
}

[ -f "${COMPOSE_FILE}" ] || fail "compose file not found: ${COMPOSE_FILE}"

vpn_id="$(service_id vpn || true)"
if [ -n "${vpn_id}" ]; then
  health="$(vpn_health "${vpn_id}")"
else
  health="missing"
fi

if [ "${MODE}" = "check" ]; then
  if [ -z "${vpn_id}" ]; then
    log "vpn: not running"
    exit 1
  fi
  log "vpn: ${health}"
  check_attachments "${vpn_id}"
  if [ "${health}" != "healthy" ]; then
    log "vpn is not healthy: run scripts/vpn-redeploy.sh (or inspect its logs)"
    exit 1
  fi
  if [ "${STALE}" = "1" ]; then
    log "at least one collector kept a stale namespace: run scripts/vpn-redeploy.sh"
    exit 1
  fi
  log "ok: vpn healthy and every collector attached to its current namespace"
  exit 0
fi

log "recreating: ${SERVICES[*]} (compose: ${COMPOSE_FILE}${PROJECT:+, project: ${PROJECT}})"
# One `up` for all four services: Compose creates the VPN, waits for its
# healthcheck (depends_on: service_healthy) and only then creates the collectors
# against the new namespace.
compose up -d --force-recreate "${SERVICES[@]}" ||
  fail "docker compose up failed; nothing else was touched"

vpn_id="$(service_id vpn || true)"
[ -n "${vpn_id}" ] || fail "the vpn container is not running after the recreate"

waited=0
while :; do
  health="$(vpn_health "${vpn_id}")"
  if [ "${health}" = "healthy" ]; then
    break
  fi
  if [ "${waited}" -ge "${WAIT_SECONDS}" ]; then
    log "vpn health is '${health}' after ${waited}s: not ready"
    log "next: docker compose logs vpn   (the readiness marker is only written after"
    log "      wg0, the hub route and the traffic guard verified)"
    exit 1
  fi
  sleep "${POLL_SECONDS}"
  waited=$((waited + POLL_SECONDS))
  vpn_id="$(service_id vpn || true)"
  [ -n "${vpn_id}" ] || fail "the vpn container disappeared while waiting for readiness"
done

check_attachments "${vpn_id}"
if [ "${STALE}" = "1" ]; then
  fail "collectors are still attached to a stale namespace after the recreate"
fi

log "recovery complete: vpn healthy, collectors attached"
log "next: docker exec vpn /bin/sh /opt/vpn/vpnctl verify   (handshake, not just readiness)"
exit 0
