#!/usr/bin/env bash
#
# Configuration validation for files/vpnctl (`check-config`).
#
# Every fixture is a temporary file with fake keys; the private key never appears in
# stdout or stderr and no network command is executed by this subcommand.
#
#   bash tests/test_vpnctl_config.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VPNCTL="${REPO_ROOT}/files/vpnctl"
SH_BIN="${SH_BIN:-/bin/sh}"

# shellcheck source=tests/lib.sh
. "${REPO_ROOT}/tests/lib.sh"
mkwork config

PRIV="$(mkkey P)"
PUB="$(mkkey U)"
PSK="$(mkkey S)"
HUB="10.77.0.1"
PEER="10.77.0.2"
LOKI="http://10.77.0.1:3100/loki/api/v1/push"

base_config() {
  cat <<EOF
[Interface]
# Tunnel address assigned by the central hub.
Address = ${PEER}/24
PrivateKey = ${PRIV}
ListenPort = 51820
DNS = 1.1.1.1

[Peer]
PublicKey = ${PUB}
PresharedKey = ${PSK}
AllowedIPs = ${HUB}/32
Endpoint = 203.0.113.10:51820
PersistentKeepalive = 25
EOF
}

# run_check <config-path> [env assignments...]
run_check() {
  conf="$1"
  shift
  set +e
  OUT="$(env VPS_NAME=vps-test LOKI_PUSH_URL="${LOKI}" \
    VPN_CONFIG_FILE="${conf}" VPN_RUN_DIR="${WORK}/run" \
    "$@" "${SH_BIN}" "${VPNCTL}" check-config 2>"${WORK}/stderr")"
  RC=$?
  set -e
  ERR="$(cat "${WORK}/stderr")"
  if [ -f "${VPNCTL}" ]; then
    case "${OUT}${ERR}" in
      *"${PRIV}"*) bad "private key leaked to output" ;;
      *) ok "private key never printed" ;;
    esac
  fi
}

expect_valid() { expect_rc 0 "$1"; }

# ---------------------------------------------------------------------------
# A standard, SCM-shaped client configuration is accepted as-is.
# ---------------------------------------------------------------------------
base_config >"${WORK}/valid.conf"
run_check "${WORK}/valid.conf"
expect_valid "valid SCM-shaped config is accepted"
expect_out_contains "peer address: ${PEER}/32" "peer address is preserved and applied as a host route"
expect_out_contains "supplied ${PEER}/24" "supplied mask is reported"
expect_out_contains "hub (loki) address: ${HUB}" "hub address is derived from the loki URL"
expect_out_contains "tcp/3100" "loki port is derived from the URL"
expect_out_contains "endpoint: 203.0.113.10:51820" "IP endpoint is accepted"
expect_out_contains "persistent keepalive: 25" "keepalive is preserved"
expect_out_contains "allowed routes: ${HUB}/32" "split route is reported"
expect_out_contains "dns: 1.1.1.1 (ignored" "public DNS from the hub config is ignored, not applied"
expect_out_not_contains "${PRIV}" "private key not in summary"

# ---------------------------------------------------------------------------
# Non-default addressing: nothing is hardcoded to 10.77.0.x.
# ---------------------------------------------------------------------------
sed -e 's|^Address = .*|Address = 192.168.77.42/24|' \
  -e "s|^AllowedIPs = .*|AllowedIPs = 192.168.77.9/32|" \
  -e 's|^Endpoint = .*|Endpoint = 198.51.100.7:51999|' \
  -e 's|^ListenPort = .*|ListenPort = 51999|' \
  "${WORK}/valid.conf" >"${WORK}/nondefault.conf"
run_check "${WORK}/nondefault.conf" LOKI_PUSH_URL="http://192.168.77.9:3100/loki/api/v1/push"
expect_valid "non-default hub/peer addressing is accepted"
expect_out_contains "peer address: 192.168.77.42/32" "non-default peer address is used"
expect_out_contains "hub (loki) address: 192.168.77.9" "non-default hub address is used"
expect_out_contains "endpoint: 198.51.100.7:51999" "non-default endpoint is used"

# ---------------------------------------------------------------------------
# Input source: missing, directory, empty, ambiguous.
# ---------------------------------------------------------------------------
run_check "${WORK}/does-not-exist.conf"
expect_rc 2 "missing client config fails"
expect_err_contains "not found" "missing config explains itself"

mkdir -p "${WORK}/confdir"
run_check "${WORK}/confdir"
expect_rc 2 "a directory at the config path fails"
expect_err_contains "directory" "directory-instead-of-file is explained"

: >"${WORK}/empty.conf"
run_check "${WORK}/empty.conf"
expect_rc 2 "empty config fails"

cp "${WORK}/valid.conf" "${WORK}/both.conf"
set +e
OUT="$(env VPS_NAME=vps-test LOKI_PUSH_URL="${LOKI}" \
  VPN_CONFIG_FILE="${WORK}/both.conf" \
  WG_CONFIG_BASE64="$(base64 <"${WORK}/valid.conf" | tr -d '\n')" \
  VPN_RUN_DIR="${WORK}/run" "${SH_BIN}" "${VPNCTL}" check-config 2>"${WORK}/stderr")"
RC=$?
set -e
ERR="$(cat "${WORK}/stderr")"
expect_rc 2 "file input plus base64 input is rejected as ambiguous"
expect_err_contains "ambiguous" "ambiguity is named"

# ---------------------------------------------------------------------------
# Required sections and keys.
# ---------------------------------------------------------------------------
sed '/^\[Interface\]/d' "${WORK}/valid.conf" >"${WORK}/no-interface.conf"
run_check "${WORK}/no-interface.conf"
expect_rc 2 "config without [Interface] fails"
expect_err_contains "[Interface]" "missing [Interface] is named"

sed '/^PrivateKey = .*/d' "${WORK}/valid.conf" >"${WORK}/no-privkey.conf"
run_check "${WORK}/no-privkey.conf"
expect_rc 2 "config without PrivateKey fails"

sed 's|^PrivateKey = .*|PrivateKey = not-a-key|' "${WORK}/valid.conf" >"${WORK}/bad-privkey.conf"
run_check "${WORK}/bad-privkey.conf"
expect_rc 2 "malformed PrivateKey fails"
expect_err_contains "PrivateKey" "malformed PrivateKey names the field"
expect_err_not_contains "not-a-key" "malformed key value is not echoed"

sed '/^AllowedIPs = .*/d' "${WORK}/valid.conf" >"${WORK}/no-allowed.conf"
run_check "${WORK}/no-allowed.conf"
expect_rc 2 "config without AllowedIPs fails"

sed '/^Endpoint = .*/d' "${WORK}/valid.conf" >"${WORK}/no-endpoint.conf"
run_check "${WORK}/no-endpoint.conf"
expect_rc 2 "config without Endpoint fails"

printf '[Interface]\nAddress = %s/24\nPrivateKey = %s\n\n[Peer]\nPublicKey = %s\nAllowedIPs = %s/32\nEndpoint = 203.0.113.10:51820\n\n[Peer]\nPublicKey = %s\nAllowedIPs = %s/32\nEndpoint = 203.0.113.11:51820\n' \
  "${PEER}" "${PRIV}" "${PUB}" "${HUB}" "${PUB}" "${HUB}" >"${WORK}/two-peers.conf"
run_check "${WORK}/two-peers.conf"
expect_rc 2 "more than one [Peer] fails"

printf '[Interface]\nAddress = %s/24\nPrivateKey = %s\nPrivateKey = %s\n\n[Peer]\nPublicKey = %s\nAllowedIPs = %s/32\nEndpoint = 203.0.113.10:51820\n' \
  "${PEER}" "${PRIV}" "${PRIV}" "${PUB}" "${HUB}" >"${WORK}/dup-key.conf"
run_check "${WORK}/dup-key.conf"
expect_rc 2 "duplicate key in a section fails"
expect_err_contains "duplicate" "duplicate is named"

# ---------------------------------------------------------------------------
# Routing scope: no default route, no over-broad prefix, hub must be covered.
# ---------------------------------------------------------------------------
sed "s|^AllowedIPs = .*|AllowedIPs = 0.0.0.0/0|" "${WORK}/valid.conf" >"${WORK}/default-route.conf"
run_check "${WORK}/default-route.conf"
expect_rc 2 "AllowedIPs 0.0.0.0/0 is rejected"
expect_err_contains "default route" "default-route rejection is explained"

sed "s|^AllowedIPs = .*|AllowedIPs = 10.0.0.0/8|" "${WORK}/valid.conf" >"${WORK}/broad.conf"
run_check "${WORK}/broad.conf"
expect_rc 2 "a route broader than the allowed minimum prefix is rejected"
expect_err_contains "/24" "minimum prefix is named"
run_check "${WORK}/broad.conf" VPN_ALLOWED_IPV4_MIN_PREFIX=8
expect_valid "the minimum prefix is configurable for a wider (still explicit) hub subnet"

sed "s|^AllowedIPs = .*|AllowedIPs = 10.99.0.1/32|" "${WORK}/valid.conf" >"${WORK}/uncovered.conf"
run_check "${WORK}/uncovered.conf"
expect_rc 2 "allowed routes that do not cover the loki host fail"
expect_err_contains "not covered" "uncovered loki host is explained"

sed "s|^AllowedIPs = .*|AllowedIPs = fd00::/64|" "${WORK}/valid.conf" >"${WORK}/v6-allowed.conf"
run_check "${WORK}/v6-allowed.conf"
expect_rc 2 "IPv6 AllowedIPs fails with an explicit scope message"
expect_err_contains "IPv6" "IPv6 scope is named"

sed "s|^Address = .*|Address = fd00::2/64|" "${WORK}/valid.conf" >"${WORK}/v6-address.conf"
run_check "${WORK}/v6-address.conf"
expect_rc 2 "IPv6 peer address fails"

# ---------------------------------------------------------------------------
# wg-quick directives: hooks and table handling never run.
# ---------------------------------------------------------------------------
for hook in PreUp PostUp PreDown PostDown; do
  awk -v hook="${hook}" '$0 == "[Peer]" { print hook " = echo unsafe" } { print }' \
    "${WORK}/valid.conf" >"${WORK}/hook.conf"
  run_check "${WORK}/hook.conf"
  expect_rc 2 "${hook} hook is rejected"
  expect_err_contains "${hook}" "${hook} is named"
  expect_err_not_contains "echo unsafe" "${hook} value is not echoed"
done

awk '$0 == "[Peer]" { print "Table = off" } { print }' "${WORK}/valid.conf" >"${WORK}/table.conf"
run_check "${WORK}/table.conf"
expect_rc 2 "wg-quick Table directive is rejected"

awk '$0 == "[Peer]" { print "Foo = bar" } { print }' "${WORK}/valid.conf" >"${WORK}/unknown.conf"
run_check "${WORK}/unknown.conf"
expect_rc 2 "unknown directive fails closed"
expect_err_contains "Foo" "unknown directive names the key"
expect_err_not_contains "bar" "unknown directive does not echo the value"

printf '[Interface]\nAddress = %s/24\nPrivateKey = %s\nno equals here\n\n[Peer]\nPublicKey = %s\nAllowedIPs = %s/32\nEndpoint = 203.0.113.10:51820\n' \
  "${PEER}" "${PRIV}" "${PUB}" "${HUB}" >"${WORK}/no-equals.conf"
run_check "${WORK}/no-equals.conf"
expect_rc 2 "a line without '=' fails"
expect_err_contains "key = value" "malformed line explains the expected shape"

# ---------------------------------------------------------------------------
# Endpoint handling and DNS.
# ---------------------------------------------------------------------------
sed 's|^Endpoint = .*|Endpoint = 203.0.113.10|' "${WORK}/valid.conf" >"${WORK}/endpoint-no-port.conf"
run_check "${WORK}/endpoint-no-port.conf"
expect_rc 2 "endpoint without a port fails"

sed 's|^Endpoint = .*|Endpoint = 203.0.113.10:99999|' "${WORK}/valid.conf" >"${WORK}/endpoint-bad-port.conf"
run_check "${WORK}/endpoint-bad-port.conf"
expect_rc 2 "endpoint with an out-of-range port fails"

sed 's|^Endpoint = .*|Endpoint = vpn.example.test:51820|' "${WORK}/valid.conf" >"${WORK}/endpoint-host.conf"
run_check "${WORK}/endpoint-host.conf"
expect_valid "hostname endpoint is accepted (resolved once at startup)"
expect_out_contains "resolve at startup" "hostname resolution is announced"
run_check "${WORK}/endpoint-host.conf" VPN_ENDPOINT_IP=203.0.113.9
expect_valid "VPN_ENDPOINT_IP supplies the resolved endpoint"
expect_out_contains "endpoint: 203.0.113.9:51820" "overridden endpoint is reported"

sed 's|^Endpoint = .*|Endpoint = 203.0.113.10:51820|' "${WORK}/valid.conf" >"${WORK}/endpoint-ip.conf"
run_check "${WORK}/endpoint-ip.conf" VPN_ENDPOINT_IP=198.51.100.1
expect_rc 2 "VPN_ENDPOINT_IP conflicting with an IP endpoint is rejected"

sed 's|^DNS = .*|DNS = 9.9.9.9, 8.8.8.8|' "${WORK}/valid.conf" >"${WORK}/dns.conf"
run_check "${WORK}/dns.conf"
expect_valid "DNS servers outside AllowedIPs do not break startup"
expect_out_contains "ignored" "DNS handling is explicit"

# ---------------------------------------------------------------------------
# Loki URL and runtime identity.
# ---------------------------------------------------------------------------
run_check "${WORK}/valid.conf" LOKI_PUSH_URL="http://loki.example.test:3100/loki/api/v1/push"
expect_rc 2 "hostname loki URL is rejected"
expect_err_contains "IPv4" "loki URL requirement is explained"

run_check "${WORK}/valid.conf" LOKI_PUSH_URL="ftp://10.77.0.1:3100/loki/api/v1/push"
expect_rc 2 "unsupported loki scheme is rejected"

run_check "${WORK}/valid.conf" LOKI_PUSH_URL="https://10.77.0.1:3100/loki/api/v1/push"
expect_valid "https keep through the tunnel is accepted"

run_check "${WORK}/valid.conf" LOKI_PUSH_URL=""
expect_rc 2 "missing loki URL fails"

run_check "${WORK}/valid.conf" VPS_NAME=""
expect_rc 2 "missing VPS_NAME fails"

# ---------------------------------------------------------------------------
# Value preservation and tolerance of real-world formatting.
# ---------------------------------------------------------------------------
sed -e 's|^Address = .*|Address = 10.77.0.2/24|' \
  -e 's|^ListenPort = .*|ListenPort = 51821|' \
  -e 's|^PersistentKeepalive = .*|PersistentKeepalive = 15|' \
  "${WORK}/valid.conf" >"${WORK}/values.conf"
run_check "${WORK}/values.conf"
expect_valid "non-default listen port and keepalive are accepted"
expect_out_contains "persistent keepalive: 15" "keepalive value is preserved"

sed 's/$/\r/' "${WORK}/valid.conf" >"${WORK}/crlf.conf"
run_check "${WORK}/crlf.conf"
expect_valid "CRLF line endings are tolerated"

sed 's|^PresharedKey = .*|PresharedKey = short|' "${WORK}/valid.conf" >"${WORK}/bad-psk.conf"
run_check "${WORK}/bad-psk.conf"
expect_rc 2 "malformed PresharedKey fails"

sed 's|^ListenPort = .*|ListenPort = 0|' "${WORK}/valid.conf" >"${WORK}/bad-port.conf"
run_check "${WORK}/bad-port.conf"
expect_rc 2 "ListenPort 0 fails"

sed 's|^PersistentKeepalive = .*|PersistentKeepalive = often|' "${WORK}/valid.conf" >"${WORK}/bad-keepalive.conf"
run_check "${WORK}/bad-keepalive.conf"
expect_rc 2 "non-numeric keepalive fails"

finish
