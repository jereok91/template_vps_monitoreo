#!/usr/bin/env bash
#
# Doc-drift contract for the operator documentation.
#
# Offline and grep-based: it asserts that the promises the implementation makes are
# written down in docs/vpn-dokploy.md and README.md, and that the fake example
# client configuration is structurally valid and accepted by `vpnctl check-config`.
# No network, no Docker, no key material.
#
#   bash tests/test_docs_contract.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOC="${REPO_ROOT}/docs/vpn-dokploy.md"
README="${REPO_ROOT}/README.md"
EXAMPLE="${REPO_ROOT}/files/wg0.conf.example"
VPNCTL="${REPO_ROOT}/files/vpnctl"
SH_BIN="${SH_BIN:-/bin/sh}"

# shellcheck source=tests/lib.sh
. "${REPO_ROOT}/tests/lib.sh"
mkwork docs

# have <file> <fixed-string> <label>
have() {
  if grep -qF -- "$2" "$1"; then
    ok "$3"
  else
    bad "$3 (missing in ${1#"${REPO_ROOT}"/}: '$2')"
  fi
}

# section <start-regex> <end-regex> <file>
section() {
  sed -n "/$1/,/$2/p" "$3"
}

missing=0
for path in "${DOC}" "${README}" "${EXAMPLE}" "${VPNCTL}"; do
  if [ ! -f "${path}" ]; then
    bad "${path#"${REPO_ROOT}"/} exists"
    missing=1
  fi
done
if [ "${missing}" = 1 ]; then
  finish
  exit 1
fi

# ---------------------------------------------------------------------------
# 1. Dokploy Compose type.
# ---------------------------------------------------------------------------
have "${DOC}" 'Docker Compose' "the operator guide names the required Compose type"
have "${DOC}" '**Stack** is not supported' "the operator guide rejects the Stack type"
if section '^## 2\. ' '^## 3\. ' "${DOC}" | grep -qF 'Stack'; then
  ok "the Compose-vs-Stack distinction is explained in the prerequisites"
else
  bad "the Compose-vs-Stack distinction is missing from the prerequisites"
fi

# ---------------------------------------------------------------------------
# 2. The three Dokploy File Mounts (repository path, File Path name, target).
# ---------------------------------------------------------------------------
while read -r repo_path file_path target; do
  have "${DOC}" "${repo_path}" "File Mount row names the repository path ${repo_path}"
  have "${DOC}" "\`${file_path}\`" "File Mount row names the File Path ${file_path}"
  have "${DOC}" "${target}" "File Mount row names the container path ${target}"
done <<'MOUNTS'
files/vpnctl vpnctl /opt/vpn/vpnctl
files/wg0.conf wg0.conf /config/wg0.conf
files/config.alloy config.alloy /etc/alloy/config.alloy
MOUNTS

have "${DOC}" 'every `./files/` occurrence' "the ./files/ -> ../files/ rewrite is stated as a rule"
for rewritten in vpnctl wg0.conf config.alloy; do
  have "${DOC}" "../files/${rewritten}" "the rewrite is shown for ${rewritten}"
done
have "${DOC}" 'Editing the repository copy does not change the deployed copy' \
  "the two-copy warning is stated"

# ---------------------------------------------------------------------------
# 3. The eight numbered operator steps.
# ---------------------------------------------------------------------------
STEPS="$(section '^## 4\. ' '^## 5\. ' "${DOC}")"
for step in 1 2 3 4 5 6 7 8; do
  if printf '%s\n' "${STEPS}" | grep -qE "^${step}\. .+"; then
    ok "operator step ${step} is documented"
  else
    bad "operator step ${step} is missing from the operator sequence"
  fi
done

# ---------------------------------------------------------------------------
# 4. Provider firewall direction table.
# ---------------------------------------------------------------------------
FIREWALL="$(section '^## 6\. ' '^## 7\. ' "${DOC}")"
if printf '%s\n' "${FIREWALL}" | grep -E '^\| *Outbound' | grep -qF 'UDP' &&
  printf '%s\n' "${FIREWALL}" | grep -E '^\| *Outbound' | grep -qF '51820'; then
  ok "the firewall table carries the outbound UDP 51820 rule"
else
  bad "the firewall table is missing the outbound UDP 51820 rule"
fi
have "${DOC}" 'no fixed inbound client listen port to open' \
  "the guide states there is no fixed inbound client listen port"
have "${DOC}" 'Never open `9100`, `8080` or `3100` publicly' \
  "the guide forbids public exporter and Loki ports"
have "${DOC}" 'stateful' "the guide explains that return traffic is stateful"

# ---------------------------------------------------------------------------
# 5. Readiness versus connectivity.
# ---------------------------------------------------------------------------
have "${DOC}" 'vpnctl status' "the guide documents 'vpnctl status'"
have "${DOC}" 'vpnctl verify' "the guide documents 'vpnctl verify'"
have "${DOC}" 'the only connectivity claim' "verify is named as the only connectivity claim"
have "${DOC}" 'A running container does not prove `wg0`' \
  "the guide separates container state from interface state"
have "${DOC}" 'a configured interface does not prove a handshake' \
  "the guide separates interface state from handshake state"

# ---------------------------------------------------------------------------
# 6. Host NIC counters, base64, cAdvisor privilege.
# ---------------------------------------------------------------------------
have "${DOC}" 'hostnet_metrics_available 0' "the guide explains hostnet_metrics_available 0"
have "${DOC}" 'base64 is NOT encryption' "the guide states that base64 is not encryption"
have "${DOC}" 'compromised privileged cAdvisor' \
  "the guide states the cAdvisor privilege caveat"
have "${DOC}" 'network scoping, not' "the guide scopes the isolation claim"

# ---------------------------------------------------------------------------
# 7. Pilot checklist coverage.
# ---------------------------------------------------------------------------
PILOT="$(section '^## 11\. ' '^## 12\. ' "${DOC}")"
for probe in 'ifconfig.me' 'default route' '/etc/resolv.conf' 'Metrics before/after' \
  'Log flow before/after' 'Restart/recreate' 'Removal'; do
  if printf '%s\n' "${PILOT}" | grep -qF -- "${probe}"; then
    ok "pilot checklist covers '${probe}'"
  else
    bad "pilot checklist is missing '${probe}'"
  fi
done

# ---------------------------------------------------------------------------
# 8. Recovery command and SCM prerequisites.
# ---------------------------------------------------------------------------
have "${DOC}" 'scripts/vpn-redeploy.sh --check' "the guide documents the recovery check"
have "${DOC}" 'scripts/vpn-redeploy.sh' "the guide documents the recovery script"
have "${DOC}" 'COMPOSE_FILE=/etc/dokploy/compose/<app>/code/docker-compose.yml' \
  "the guide points the recovery script at the Dokploy compose file"
have "${DOC}" 'cd /etc/dokploy/compose/<app>/code' \
  "the guide runs the removal from the Dokploy compose directory"
have "${DOC}" 'alphanumeric' "the guide states the alphanumeric peer-name rule"
have "${DOC}" 'peer.sh show' "the guide states the peer.sh show export step"
have "${DOC}" 'WG_SERVERURL' "the guide states the WG_SERVERURL requirement"
have "${DOC}" 'VPN_ENDPOINT_IP' "the guide states the VPN_ENDPOINT_IP alternative"
have "${DOC}" 'Dokploy File Mount' "the guide documents the Dokploy File Mount step"

# ---------------------------------------------------------------------------
# 9. Doc and example-config hygiene.
# ---------------------------------------------------------------------------
if section '^## 1\. ' '^## 2\. ' "${DOC}" | grep -qF 'vpn_egress'; then
  ok "the guide names the only bridge the VPN service joins"
else
  bad "the guide does not name the dedicated vpn_egress bridge"
fi
have "${DOC}" 'no public exporter ports' "the guide states there are no public exporter ports"

have "${README}" 'docs/vpn-dokploy.md' "README links the operator guide"
have "${README}" 'bash tests/run.sh' "README documents the test runner"
have "${README}" 'no published ports' "README states there are no published ports"
have "${README}" 'two copies' "README keeps the two-copy note"
have "${README}" 'Editing the repository copy does not change the deployed pipeline' \
  "README keeps the two-copy warning"

have "${EXAMPLE}" 'FAKE' "the example client config carries a FAKE marker"
for line in 'Address = 10.77.0.2/24' 'ListenPort = 51820' 'DNS = 1.1.1.1' \
  'AllowedIPs = 10.77.0.1/32' 'Endpoint = 203.0.113.10:51820' 'PersistentKeepalive = 25'; do
  have "${EXAMPLE}" "${line}" "the example client config keeps '${line}'"
done

keys_ok=1
for key in PrivateKey PublicKey PresharedKey; do
  value="$(awk -v k="${key}" '$1 == k && $2 == "=" { print $3; exit }' "${EXAMPLE}")"
  [ "${#value}" -eq 44 ] || keys_ok=0
  case "${value}" in
    *=) ;;
    *) keys_ok=0 ;;
  esac
  case "${value}" in
    ''|*[!A-Za-z0-9+/=]*) keys_ok=0 ;;
  esac
  body="${value%=}"
  fillers="$(printf '%s' "${body}" | fold -w 1 | sort -u | tr -d '\n')"
  if [ "${#fillers}" -ne 1 ] || [ "${#body}" -ne 43 ]; then
    keys_ok=0
  fi
done
if [ "${keys_ok}" = 1 ]; then
  ok "every example key is a 44-character, single-character-filler placeholder"
else
  bad "the example keys are not obviously fake 44-character placeholders"
fi

# `check-config` must accept the example with the documented hub address.
set +e
OUT="$(env VPS_NAME=x LOKI_PUSH_URL='http://10.77.0.1:3100/loki/api/v1/push' \
  VPN_CONFIG_FILE="${EXAMPLE}" "${SH_BIN}" "${VPNCTL}" check-config 2>"${WORK}/stderr")"
RC=$?
set -e
ERR="$(cat "${WORK}/stderr")"
if [ "${RC}" = 0 ]; then
  ok "vpnctl check-config accepts files/wg0.conf.example (exit 0)"
else
  bad "vpnctl check-config rejected files/wg0.conf.example (exit ${RC})"
  printf '    stderr: %s\n' "${ERR}" >&2
fi
case "${OUT}" in
  *"configuration ok"*) ok "check-config reports the example configuration as ok" ;;
  *) bad "check-config did not report 'configuration ok' for the example" ;;
esac
case "${OUT}" in
  *"allowed routes: 10.77.0.1/32"*) ok "check-config resolves the example to the hub-only route" ;;
  *) bad "check-config did not resolve the example to 10.77.0.1/32" ;;
esac

finish
