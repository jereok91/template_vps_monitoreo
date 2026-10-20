#!/usr/bin/env bash
#
# Contract test for scripts/vpn-redeploy.sh (recreate + re-attach procedure).
#
# `docker` is stubbed with state in $WORK: it emulates `compose ps`, `compose up`
# (recreating only the services named on the command line, like Compose does) and
# `inspect`. No Docker daemon is contacted and no namespace is created.
#
#   bash tests/test_redeploy_contract.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/vpn-redeploy.sh"

# shellcheck source=tests/lib.sh
. "${REPO_ROOT}/tests/lib.sh"
mkwork redeploy

COMPOSE="${WORK}/project/docker-compose.yml"
mkdir -p "${WORK}/project" "${WORK}/bin" "${WORK}/state"
printf 'services: {}\n' >"${COMPOSE}"

cat >"${WORK}/bin/docker" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$*" >>"${DOCKER_LOG:?}"
state="${DOCKER_STATE:?}"
[ -d "${state}" ] || exit 1

if [ "${1:-}" = "compose" ]; then
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -p|-f) shift 2 ;;
      *) break ;;
    esac
  done
  sub="${1:-}"
  [ "$#" -gt 0 ] && shift
  case "${sub}" in
    ps)
      [ "${1:-}" = "-q" ] && shift
      svc="${1:-}"
      id="$(cat "${state}/id_${svc}" 2>/dev/null)" || exit 1
      [ -n "${id}" ] || exit 1
      printf '%s\n' "${id}"
      exit 0
      ;;
    up)
      if [ "${STUB_UP_FAIL:-0}" = "1" ]; then exit 1; fi
      n="$(cat "${state}/gen" 2>/dev/null || echo 0)"
      n=$((n + 1))
      printf '%s\n' "${n}" >"${state}/gen"
      vpn="vpn-${n}"
      printf '%s\n' "${vpn}" >"${state}/id_vpn"
      if [ "${STUB_HEALTH:-healthy}" = "healthy" ]; then
        printf 'healthy\n' >"${state}/health_${vpn}"
      else
        printf 'starting\n' >"${state}/health_${vpn}"
      fi
      for arg in "$@"; do
        case "${arg}" in
          -d|--force-recreate) continue ;;
        esac
        printf '%s\n' "${arg}" >>"${state}/up_services"
        case "${arg}" in
          node_exporter|cadvisor|alloy)
            cid="${arg}-${n}"
            printf '%s\n' "${cid}" >"${state}/id_${arg}"
            printf 'container:%s\n' "${vpn}" >"${state}/net_${cid}"
            ;;
        esac
      done
      exit 0
      ;;
    down|restart) exit 0 ;;
    *) exit 0 ;;
  esac
fi

if [ "${1:-}" = "inspect" ]; then
  # docker inspect -f <format> <id>
  fmt="${3:-}"
  id="${4:-}"
  case "${fmt}" in
    *NetworkMode*) cat "${state}/net_${id}" 2>/dev/null || printf 'default\n' ;;
    *Health*) cat "${state}/health_${id}" 2>/dev/null || printf 'none\n' ;;
    *) printf 'unknown\n' ;;
  esac
  exit 0
fi

exit 1
STUB
chmod +x "${WORK}/bin/docker"

export PATH="${WORK}/bin:${PATH}"
export DOCKER_LOG="${WORK}/docker.log"
export DOCKER_STATE="${WORK}/state"
export COMPOSE_FILE="${COMPOSE}"

: >"${DOCKER_LOG}"

seed() { # <attached|stale>
  rm -rf "${DOCKER_STATE}"
  mkdir -p "${DOCKER_STATE}"
  printf '0\n' >"${DOCKER_STATE}/gen"
  printf 'vpn-0\n' >"${DOCKER_STATE}/id_vpn"
  printf 'healthy\n' >"${DOCKER_STATE}/health_vpn-0"
  for svc in node_exporter cadvisor alloy; do
    printf '%s-0\n' "${svc}" >"${DOCKER_STATE}/id_${svc}"
    if [ "$1" = "stale" ]; then
      printf 'container:vpn-old\n' >"${DOCKER_STATE}/net_${svc}-0"
    else
      printf 'container:vpn-0\n' >"${DOCKER_STATE}/net_${svc}-0"
    fi
  done
}

# ---------------------------------------------------------------------------
# --check: healthy + attached passes; stale attachment and unhealthy VPN fail.
# ---------------------------------------------------------------------------
seed attached
capture bash "${SCRIPT}" --check
expect_rc 0 "check passes when every collector is attached to the current namespace"
expect_err_contains "ok: vpn healthy" "check reports the healthy attached state"

seed stale
capture bash "${SCRIPT}" --check
expect_rc 1 "check fails on a stale namespace attachment"
expect_err_contains "STALE network mode" "check names the stale attachment"
expect_err_contains "vpn-redeploy.sh" "check prints the recovery action"

seed attached
printf 'starting\n' >"${DOCKER_STATE}/health_vpn-0"
capture bash "${SCRIPT}" --check
expect_rc 1 "check fails while the vpn is not healthy"
expect_err_contains "not healthy" "unhealthy vpn is explained"

# ---------------------------------------------------------------------------
# Redeploy: one ordered up for exactly the four services, then verified.
# ---------------------------------------------------------------------------
seed stale
: >"${DOCKER_LOG}"
capture env VPN_REDEPLOY_POLL_SECONDS=1 VPN_REDEPLOY_WAIT_SECONDS=5 bash "${SCRIPT}"
expect_rc 0 "redeploy succeeds and recovers a stale attachment"
grep -qF 'up -d --force-recreate vpn node_exporter cadvisor alloy' "${DOCKER_LOG}" &&
  ok "one ordered up recreates the vpn and its three collectors" ||
  bad "the recreate command does not list the four services in order"
if grep -qE '(^| )down( |$)|--remove-orphans' "${DOCKER_LOG}"; then
  bad "redeploy must not use down or --remove-orphans"
else
  ok "redeploy never downs the project or removes orphans"
fi
sorted_services="$(sort "${DOCKER_STATE}/up_services" | tr '\n' ' ')"
if [ "${sorted_services}" = "alloy cadvisor node_exporter vpn " ]; then
  ok "exactly the four monitoring services were recreated"
else
  bad "unexpected service set recreated: ${sorted_services}"
fi
if grep -qF 'recovery complete' "${WORK}/stderr"; then
  ok "recovery is reported as complete"
else
  bad "recovery completion is not reported"
fi
capture bash "${SCRIPT}" --check
expect_rc 0 "the post-redeploy check passes"

# ---------------------------------------------------------------------------
# Project scoping and failure paths.
# ---------------------------------------------------------------------------
seed attached
: >"${DOCKER_LOG}"
capture env COMPOSE_PROJECT_NAME=dokploy-app VPN_REDEPLOY_POLL_SECONDS=1 VPN_REDEPLOY_WAIT_SECONDS=5 bash "${SCRIPT}"
expect_rc 0 "redeploy works with an explicit Dokploy project"
grep -qF 'compose -p dokploy-app -f' "${DOCKER_LOG}" &&
  ok "the Dokploy project name is passed to compose" ||
  bad "the Dokploy project name was not passed to compose"

seed attached
capture env STUB_UP_FAIL=1 bash "${SCRIPT}"
expect_rc 1 "a failing compose up fails the redeploy"
expect_err_contains "docker compose up failed" "compose failure is reported"

seed attached
: >"${DOCKER_LOG}"
printf 'starting\n' >"${DOCKER_STATE}/health_unused"
capture env STUB_HEALTH=starting VPN_REDEPLOY_POLL_SECONDS=1 VPN_REDEPLOY_WAIT_SECONDS=0 bash "${SCRIPT}"
expect_rc 1 "an unhealthy vpn after recreate fails the redeploy"
expect_err_contains "not ready" "the wait budget failure is explained"

capture bash "${SCRIPT}" --bogus
expect_rc 2 "unknown arguments are rejected"

finish
