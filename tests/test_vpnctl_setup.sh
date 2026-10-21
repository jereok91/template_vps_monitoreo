#!/usr/bin/env bash
#
# Runtime contract for files/vpnctl: setup order, sanitized setconf, traffic guard,
# readiness marker, supervision, healthcheck and verify.
#
# `ip`, `wg` and `iptables` are stubs in $WORK/bin that log every argument and keep
# their state in $WORK/state. No interface is created, no real firewall rule is
# installed and no server is contacted.
#
#   bash tests/test_vpnctl_setup.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VPNCTL="${REPO_ROOT}/files/vpnctl"
SH_BIN="${SH_BIN:-/bin/sh}"

# shellcheck source=tests/lib.sh
. "${REPO_ROOT}/tests/lib.sh"
mkwork setup

PRIV="$(mkkey P)"
PUB="$(mkkey U)"
PSK="$(mkkey S)"
HUB="10.77.0.1"
PEER="10.77.0.2"
ENDPOINT_IP="203.0.113.10"
ENDPOINT="${ENDPOINT_IP}:51820"
GATEWAY="192.0.2.1"
EGRESS="eth9"
LOKI="http://${HUB}:3100/loki/api/v1/push"

mkdir -p "${WORK}/bin" "${WORK}/state" "${WORK}/run" "${WORK}/textfile" "${WORK}/proc/1/net"

UP_PID=''

# ---------------------------------------------------------------------------
# Stubs
# ---------------------------------------------------------------------------
cat >"${WORK}/bin/ip" <<'STUB'
#!/bin/sh
set -u
printf 'ip %s\n' "$*" >>"${STUB_LOG:?}"
state="${STUB_STATE:?}"
cmd=${1:-}
[ "$#" -gt 0 ] && shift
case "$cmd" in
  route)
    sub=${1:-}
    [ "$#" -gt 0 ] && shift
    case "$sub" in
      show)
        case "${1:-}" in
          default) awk '$1 == "default"' "$state/routes" 2>/dev/null || true ;;
          dev) awk -v i="${2:-}" '$NF == i' "$state/routes" 2>/dev/null || true ;;
          *) cat "$state/routes" 2>/dev/null || true ;;
        esac
        exit 0
        ;;
      replace)
        entry=${1:-}
        [ "$#" -gt 0 ] && shift
        for a in "$@"; do entry="${entry} $a"; done
        awk -v p="${entry%% *}" '$1 != p' "$state/routes" >"$state/routes.new" 2>/dev/null || true
        mv "$state/routes.new" "$state/routes"
        printf '%s\n' "$entry" >>"$state/routes"
        exit 0
        ;;
      del)
        target=${1:-}
        awk -v p="$target" '$1 != p' "$state/routes" >"$state/routes.new" 2>/dev/null || true
        mv "$state/routes.new" "$state/routes"
        exit 0
        ;;
    esac
    exit 0
    ;;
  link)
    sub=${1:-}
    [ "$#" -gt 0 ] && shift
    case "$sub" in
      show)
        iface=${2:-}
        if grep -qx "$iface" "$state/links" 2>/dev/null; then
          printf '%s: <POINTOPOINT,NOARP,UP,LOWER_UP> mtu 1420\n' "$iface"
          exit 0
        fi
        printf 'Device "%s" does not exist.\n' "$iface" >&2
        exit 1
        ;;
      add)
        if [ "${STUB_FAIL_LINK_ADD:-0}" = 1 ]; then
          printf 'RTNETLINK answers: Operation not permitted\n' >&2
          exit 1
        fi
        printf '%s\n' "${2:-}" >>"$state/links"
        exit 0
        ;;
      del)
        grep -vx "${2:-}" "$state/links" >"$state/links.new" 2>/dev/null || true
        mv "$state/links.new" "$state/links"
        exit 0
        ;;
      set) exit 0 ;;
    esac
    exit 0
    ;;
  addr)
    sub=${1:-}
    [ "$#" -gt 0 ] && shift
    case "$sub" in
      add)
        printf '%s dev %s\n' "${1:-}" "${3:-}" >>"$state/addrs"
        exit 0
        ;;
      show)
        iface=${2:-}
        awk -v i="$iface" '$NF == i { printf "    inet %s scope global %s\n", $1, i }' "$state/addrs" 2>/dev/null || true
        exit 0
        ;;
    esac
    exit 0
    ;;
esac
exit 0
STUB

cat >"${WORK}/bin/wg" <<'STUB'
#!/bin/sh
set -u
printf 'wg %s\n' "$*" >>"${STUB_LOG:?}"
state="${STUB_STATE:?}"
case "${1:-}" in
  setconf)
    if [ "${STUB_FAIL_SETCONF:-0}" = 1 ]; then
      printf 'Unable to modify interface: Operation not permitted\n' >&2
      exit 1
    fi
    cp "${3:-}" "$state/setconf.snapshot" 2>/dev/null || exit 1
    exit 0
    ;;
  show)
    case "${3:-}" in
      endpoints)
        [ "${STUB_WG_NO_ENDPOINT:-0}" = 1 ] && exit 0
        ep=$(awk '$1 == "Endpoint" { print $3; exit }' "$state/setconf.snapshot" 2>/dev/null)
        printf '%s\t%s\n' "${STUB_PEERKEY:-peer}" "$ep"
        exit 0
        ;;
      latest-handshakes)
        hs=$(cat "$state/handshake" 2>/dev/null || printf 0)
        printf '%s\t%s\n' "${STUB_PEERKEY:-peer}" "$hs"
        exit 0
        ;;
      transfer)
        printf '%s\t%s\t%s\n' "${STUB_PEERKEY:-peer}" 1024 2048
        exit 0
        ;;
    esac
    exit 0
    ;;
esac
exit 0
STUB

cat >"${WORK}/bin/iptables" <<'STUB'
#!/bin/sh
set -u
printf 'iptables %s\n' "$*" >>"${STUB_LOG:?}"
state="${STUB_STATE:?}"
db="$state/iptables"
[ -f "$db" ] || : >"$db"
op=${1:-}
[ "$#" -gt 0 ] && shift
case "$op" in
  -F)
    chain=${1:-}
    printf '%s %s\n' -F "$chain" >>"$db"
    awk -v c="$chain" '!($1 == "-A" && $2 == c)' "$db" >"$db.new" && mv "$db.new" "$db"
    ;;
  -P)
    chain=${1:-}
    pol=${2:-}
    awk -v c="$chain" '!($1 == "-P" && $2 == c)' "$db" >"$db.new" && mv "$db.new" "$db"
    printf '%s %s %s\n' -P "$chain" "$pol" >>"$db"
    ;;
  -A)
    if [ -f "${STUB_READY:-/nonexistent}" ]; then
      printf 'ready-present\n' >>"$state/ready_at_guard"
    fi
    rule="-A $*"
    if [ -n "${STUB_FAIL_RULE:-}" ]; then
      case "$rule" in
        *"$STUB_FAIL_RULE"*)
          printf 'iptables: Operation not permitted\n' >&2
          exit 1
          ;;
      esac
    fi
    printf '%s\n' "$rule" >>"$db"
    ;;
  -C)
    want="-A $*"
    if awk -v w="$want" '$0 == w { found = 1 } END { exit(found ? 0 : 1) }' "$db"; then
      exit 0
    fi
    printf 'iptables: Bad rule.\n' >&2
    exit 1
    ;;
  -S)
    chain=${1:-}
    awk -v c="$chain" '($1 == "-P" || $1 == "-A") && $2 == c' "$db"
    ;;
esac
exit 0
STUB

chmod +x "${WORK}/bin/ip" "${WORK}/bin/wg" "${WORK}/bin/iptables"

# ip6tables uses the same stub with its own state file: the guard must lock IPv6
# down as well, because the tunnel only carries IPv4.
sed -e "s|'iptables %s|'ip6tables %s|" -e 's|^db="$state/iptables"|db="$state/ip6tables"|' \
  "${WORK}/bin/iptables" >"${WORK}/bin/ip6tables"
chmod +x "${WORK}/bin/ip6tables"

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------
cat >"${WORK}/client.conf" <<EOF
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
Endpoint = ${ENDPOINT}
PersistentKeepalive = 25
EOF

cat >"${WORK}/proc/1/net/dev" <<'EOF'
Inter-|   Receive                                                |  Transmit
 face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
    lo:    9288      96    0    0    0     0          0         0     9288      96    0    0    0     0       0          0
  eth0:  1234567     890    1    2    3     4          5         6   7654321     654    7    8    9    10      11         12
EOF

# reset_state [no-default]
reset_state() {
  : >"${WORK}/cmd.log"
  : >"${WORK}/state/routes"
  : >"${WORK}/state/links"
  : >"${WORK}/state/addrs"
  : >"${WORK}/state/iptables"
  : >"${WORK}/state/ip6tables"
  : >"${WORK}/state/ready_at_guard"
  if [ "${1:-}" != "no-default" ]; then
    printf 'default via %s dev %s proto static\n' "${GATEWAY}" "${EGRESS}" >>"${WORK}/state/routes"
  fi
}

# export_env [supervise-interval]
export_env() {
  export VPS_NAME=vps-test
  export LOKI_PUSH_URL="${LOKI}"
  export VPN_CONFIG_FILE="${WORK}/client.conf"
  export VPN_RUN_DIR="${WORK}/run"
  export VPN_TEXTFILE_DIR="${WORK}/textfile"
  export VPN_HOST_PROC="${WORK}/proc"
  export VPN_SUPERVISE_INTERVAL="${1:-1}"
  export STUB_LOG="${WORK}/cmd.log"
  export STUB_STATE="${WORK}/state"
  export STUB_PEERKEY="${PUB}"
  export STUB_READY="${WORK}/run/ready"
  export STUB_NO_DEFAULT=0
  export STUB_FAIL_SETCONF=0
  export STUB_FAIL_LINK_ADD=0
  export STUB_WG_NO_ENDPOINT=0
  export STUB_FAIL_RULE=''
  export VPN_NAMESPACE_IPV6=1
  export PATH="${WORK}/bin:${PATH}"
  unset WG_CONFIG_BASE64 VPN_ENDPOINT_IP VPN_HOSTNET_ONCE 2>/dev/null || true
}

cleanup_procs() {
  if [ -n "${UP_PID}" ] && kill -0 "${UP_PID}" 2>/dev/null; then
    kill -TERM "${UP_PID}" 2>/dev/null || true
    wait_for_exit "${UP_PID}" 60 || true
    wait "${UP_PID}" 2>/dev/null || true
  fi
  UP_PID=''
}

# launch_up <outfile>: runs `up` in the background with the real pid in UP_PID.
launch_up() {
  (exec "${SH_BIN}" "${VPNCTL}" up >"$1" 2>"$1.err") &
  UP_PID=$!
}

wait_for_file() {
  wf_i=0
  while [ ! -f "$1" ]; do
    wf_i=$((wf_i + 1))
    if [ "${wf_i}" -gt "$2" ]; then return 1; fi
    sleep 0.1
  done
  return 0
}

wait_for_exit() {
  we_i=0
  while kill -0 "$1" 2>/dev/null; do
    we_i=$((we_i + 1))
    if [ "${we_i}" -gt "$2" ]; then return 1; fi
    sleep 0.1
  done
  return 0
}

# first_line_of <literal>: line number of the first matching command log entry.
first_line_of() {
  grep -n -F "$1" "${WORK}/cmd.log" 2>/dev/null | head -n 1 | cut -d: -f1
}

expect_present() {
  if [ -n "$(first_line_of "$1")" ]; then
    ok "setup step present: $1"
  else
    bad "setup step missing: $1"
    printf '    cmd.log:\n' >&2
    sed -e 's/^/      /' "${WORK}/cmd.log" >&2
  fi
}

expect_before() {
  eb_a=$(first_line_of "$1" || true)
  eb_b=$(first_line_of "$2" || true)
  if [ -n "${eb_a}" ] && [ -n "${eb_b}" ] && [ "${eb_a}" -lt "${eb_b}" ]; then
    ok "'$1' runs before '$2'"
  else
    bad "'$1' must run before '$2' (lines: '${eb_a:-absent}' / '${eb_b:-absent}')"
  fi
}

expect_file_contains() {
  if grep -q -F -- "$2" "$1" 2>/dev/null; then
    ok "$3"
  else
    bad "$3 (missing '$2')"
  fi
}

expect_file_not_contains() {
  if grep -q -F -- "$2" "$1" 2>/dev/null; then
    bad "$3 (unexpected '$2')"
  else
    ok "$3"
  fi
}

expect_mode() {
  em_mode="$(file_mode "$1" 2>/dev/null || printf 'missing')"
  if [ "${em_mode}" = "$2" ]; then
    ok "$3 (mode ${em_mode})"
  else
    bad "$3 (expected mode $2, got ${em_mode})"
  fi
}

# ---------------------------------------------------------------------------
# 1. check-config is pure: no network command, no leaked key material.
# ---------------------------------------------------------------------------
reset_state
export_env 10
capture "${SH_BIN}" "${VPNCTL}" check-config
expect_rc 0 "check-config accepts the SCM-shaped client config"
expect_out_contains "configuration ok" "check-config prints the resolved plan"
if [ -s "${WORK}/cmd.log" ]; then
  bad "check-config must not call ip/wg/iptables"
  sed -e 's/^/    /' "${WORK}/cmd.log" >&2
else
  ok "check-config never calls ip/wg/iptables"
fi

# ---------------------------------------------------------------------------
# 2. Full `up` run: order, sanitized setconf, guard, readiness.
# ---------------------------------------------------------------------------
reset_state
export_env 1
launch_up "${WORK}/up.out"
if wait_for_file "${WORK}/run/ready" 60; then
  ok "up publishes the readiness marker"
else
  bad "up did not publish ${WORK}/run/ready"
  printf '    stdout: %s\n    stderr: %s\n' "$(cat "${WORK}/up.out")" "$(cat "${WORK}/up.out.err")" >&2
fi

expect_out_contains "configuration ok" "up prints the configuration summary"
if grep -q -F -- "${PRIV}" "${WORK}/up.out" "${WORK}/up.out.err" 2>/dev/null; then
  bad "up leaked the private key"
else
  ok "up never prints the private key"
fi
if grep -q -F -- "${PSK}" "${WORK}/up.out" "${WORK}/up.out.err" 2>/dev/null; then
  bad "up leaked the preshared key"
else
  ok "up never prints the preshared key"
fi

# Ordered setup steps.
expect_present "ip route show default"
expect_present "ip link add dev wg0 type wireguard"
expect_present "wg setconf wg0 ${WORK}/run/wg0.setconf"
expect_present "ip addr add ${PEER}/32 dev wg0"
expect_present "ip link set dev wg0 mtu 1420"
expect_present "ip link set dev wg0 up"
expect_present "ip route replace ${HUB}/32 dev wg0"
expect_present "ip route replace ${ENDPOINT_IP}/32 via ${GATEWAY} dev ${EGRESS}"
expect_present "ip route del default"

expect_before "ip route show default" "ip link add dev wg0 type wireguard"
expect_before "ip link add dev wg0 type wireguard" "wg setconf wg0"
expect_before "wg setconf wg0" "ip addr add ${PEER}/32 dev wg0"
expect_before "ip addr add ${PEER}/32 dev wg0" "ip link set dev wg0 up"
expect_before "ip link set dev wg0 up" "ip route replace ${HUB}/32 dev wg0"
expect_before "ip route replace ${HUB}/32 dev wg0" "iptables -A INPUT -i lo -j ACCEPT"
expect_before "iptables -A INPUT -i ${EGRESS} -s ${ENDPOINT_IP} -p udp -j ACCEPT" \
  "ip route replace ${ENDPOINT_IP}/32 via ${GATEWAY} dev ${EGRESS}"
expect_before "ip route replace ${ENDPOINT_IP}/32 via ${GATEWAY} dev ${EGRESS}" \
  "ip route del default"

add_count=$(grep -c -F "ip link add dev wg0" "${WORK}/cmd.log" 2>/dev/null || printf 0)
if [ "${add_count}" = 1 ]; then
  ok "the interface is created exactly once"
else
  bad "expected exactly one 'ip link add', got ${add_count}"
fi

# Sanitized wg setconf input.
SNAPSHOT="${WORK}/state/setconf.snapshot"
if [ -f "${SNAPSHOT}" ]; then
  ok "the sanitized setconf existed while wg setconf ran"
  expect_file_contains "${SNAPSHOT}" "PrivateKey = ${PRIV}" "setconf keeps the private key"
  expect_file_contains "${SNAPSHOT}" "PresharedKey = ${PSK}" "setconf keeps the preshared key"
  expect_file_contains "${SNAPSHOT}" "AllowedIPs = ${HUB}/32" "setconf keeps AllowedIPs"
  expect_file_contains "${SNAPSHOT}" "Endpoint = ${ENDPOINT}" "setconf keeps the endpoint"
  expect_file_contains "${SNAPSHOT}" "PersistentKeepalive = 25" "setconf keeps the keepalive"
  expect_file_contains "${SNAPSHOT}" "ListenPort = 51820" "setconf keeps ListenPort"
  expect_file_not_contains "${SNAPSHOT}" "Address" "setconf has no Address directive"
  expect_file_not_contains "${SNAPSHOT}" "DNS" "setconf has no DNS directive"
  expect_file_not_contains "${SNAPSHOT}" "MTU" "setconf has no MTU directive"
  expect_file_not_contains "${SNAPSHOT}" "PreUp" "setconf has no hooks"
  expect_file_not_contains "${SNAPSHOT}" "PostUp" "setconf has no hooks"
  expect_file_not_contains "${SNAPSHOT}" "Table" "setconf has no Table directive"
else
  bad "wg setconf never saw a sanitized configuration file"
fi
expect_mode "${WORK}/run/wg0.setconf" 600 "the runtime setconf file is private"

# Guard: exactly the documented rules and policies.
cat >"${WORK}/expected.guard" <<EOF
-P INPUT DROP
-P OUTPUT DROP
-P FORWARD DROP
-A INPUT -i lo -j ACCEPT
-A OUTPUT -o lo -j ACCEPT
-A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
-A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
-A OUTPUT -o wg0 -d ${HUB} -p tcp --dport 3100 -j ACCEPT
-A OUTPUT -o wg0 -d ${HUB} -p icmp --icmp-type echo-request -j ACCEPT
-A INPUT -i wg0 -s ${HUB} -p tcp -m multiport --dports 9100,8080 -j ACCEPT
-A INPUT -i wg0 -s ${HUB} -p icmp --icmp-type echo-request -j ACCEPT
-A OUTPUT -o ${EGRESS} -d ${ENDPOINT_IP} -p udp --dport 51820 -j ACCEPT
-A INPUT -i ${EGRESS} -s ${ENDPOINT_IP} -p udp -j ACCEPT
EOF
awk '$1 == "-P" || $1 == "-A"' "${WORK}/state/iptables" >"${WORK}/state/iptables.guard" 2>/dev/null || true
if cmp -s "${WORK}/expected.guard" "${WORK}/state/iptables.guard"; then
  ok "the guard contains exactly the 3 policies and the intended allow rules"
else
  bad "guard content differs from the intended rule set"
  diff -u "${WORK}/expected.guard" "${WORK}/state/iptables.guard" >&2 || true
fi
guard_rule_count=$(grep -c '^-A ' "${WORK}/state/iptables.guard" 2>/dev/null || printf 0)
guard_policy_count=$(grep -c '^-P ' "${WORK}/state/iptables.guard" 2>/dev/null || printf 0)
if [ "${guard_policy_count}" = 3 ]; then
  ok "all three filter policies are set"
else
  bad "expected 3 policies, got ${guard_policy_count}"
fi
if [ "${guard_rule_count}" = 10 ]; then
  ok "the 10 documented allow rules are installed"
else
  bad "expected 10 guard rules, got ${guard_rule_count}"
fi
v6_policies=$(grep -c '^-P .* DROP' "${WORK}/state/ip6tables" 2>/dev/null || printf 0)
if [ "${v6_policies}" = 3 ]; then
  ok "IPv6 is locked down with 3 DROP policies"
else
  bad "expected 3 IPv6 DROP policies, got ${v6_policies}"
fi
if grep -qx -- '-A OUTPUT -o lo -j ACCEPT' "${WORK}/state/ip6tables" 2>/dev/null; then
  ok "IPv6 allows loopback only"
else
  bad "IPv6 loopback rule is missing"
fi
if [ -s "${WORK}/state/ready_at_guard" ]; then
  bad "the readiness marker existed while the guard was still being applied"
else
  ok "the readiness marker is written only after the guard"
fi

# Readiness marker.
READY="${WORK}/run/ready"
expect_mode "${READY}" 600 "the readiness marker is private"
expect_file_contains "${READY}" "version=1" "marker records the vpnctl version"
expect_file_contains "${READY}" "iface=wg0" "marker records the interface"
expect_file_contains "${READY}" "addr=${PEER}/32" "marker records the applied address"
expect_file_contains "${READY}" "hub=${HUB}" "marker records the hub address"
expect_file_contains "${READY}" "loki_port=3100" "marker records the loki port"
expect_file_contains "${READY}" "exporter_ports=9100,8080" "marker records the exporter ports"
expect_file_contains "${READY}" "endpoint_ip=${ENDPOINT_IP}" "marker records the endpoint address"
expect_file_contains "${READY}" "endpoint_port=51820" "marker records the endpoint port"
expect_file_contains "${READY}" "egress_if=${EGRESS}" "marker records the egress interface"
expect_file_contains "${READY}" "gateway=${GATEWAY}" "marker records the gateway"
expect_file_contains "${READY}" "mtu=1420" "marker records the MTU"
expect_file_contains "${READY}" "allowed_ips=${HUB}/32" "marker records the allowed routes"
expect_file_contains "${READY}" "keepalive=25" "marker records the keepalive"
if grep -q -E '^written_at=[0-9]+$' "${READY}" 2>/dev/null; then
  ok "marker records an epoch timestamp"
else
  bad "marker has no numeric written_at"
fi
expect_file_not_contains "${READY}" "${PRIV}" "the marker has no private key"
expect_file_not_contains "${READY}" "${PSK}" "the marker has no preshared key"

# healthcheck.
capture "${SH_BIN}" "${VPNCTL}" healthcheck
expect_rc 0 "healthcheck reports readiness after up"

# Hub route removed from the interface: readiness must drop.
awk -v p="${HUB}/32" '$1 != p' "${WORK}/state/routes" >"${WORK}/state/routes.new"
mv "${WORK}/state/routes.new" "${WORK}/state/routes"
capture "${SH_BIN}" "${VPNCTL}" healthcheck
expect_rc 1 "healthcheck fails when the hub route is gone"

# An allow rule removed while the policies remain DROP must fail readiness too.
printf '%s/32 dev wg0\n' "${HUB}" >>"${WORK}/state/routes"
grep -v -x -- "-A OUTPUT -o ${EGRESS} -d ${ENDPOINT_IP} -p udp --dport 51820 -j ACCEPT" \
  "${WORK}/state/iptables" >"${WORK}/state/iptables.new" || true
mv "${WORK}/state/iptables.new" "${WORK}/state/iptables"
capture "${SH_BIN}" "${VPNCTL}" healthcheck
expect_rc 1 "healthcheck fails when a guard allow rule is missing"

# verify: handshake freshness is the only connectivity claim.
printf '0' >"${WORK}/state/handshake"
capture "${SH_BIN}" "${VPNCTL}" verify
expect_rc 1 "verify fails with no handshake (never)"
expect_out_contains "never" "a missing handshake is reported as never"
printf '%s' "$(($(date +%s) - 400))" >"${WORK}/state/handshake"
capture "${SH_BIN}" "${VPNCTL}" verify
expect_rc 1 "verify fails on a stale handshake"
expect_out_contains "stale" "a stale handshake is reported as stale"
printf '%s' "$(date +%s)" >"${WORK}/state/handshake"
capture "${SH_BIN}" "${VPNCTL}" verify
expect_rc 0 "verify accepts a fresh handshake"

# Supervision: losing the interface terminates the process so Docker restarts it.
grep -vx 'wg0' "${WORK}/state/links" >"${WORK}/state/links.new" || true
mv "${WORK}/state/links.new" "${WORK}/state/links"
if wait_for_exit "${UP_PID}" 60; then
  ok "the supervisor exits when wg0 disappears"
else
  bad "the supervisor kept running after wg0 disappeared"
fi
sup_rc=0
wait "${UP_PID}" 2>/dev/null || sup_rc=$?
UP_PID=''
if [ "${sup_rc}" -ne 0 ]; then
  ok "a lost interface exits non-zero (exit ${sup_rc})"
else
  bad "a lost interface must exit non-zero, got ${sup_rc}"
fi
if [ -e "${WORK}/run/ready" ]; then
  bad "the readiness marker survived a failed tunnel"
else
  ok "the readiness marker is removed when the tunnel fails"
fi

# ---------------------------------------------------------------------------
# 3. Supervision of the guard: a flipped policy is repaired, healthcheck notices.
# ---------------------------------------------------------------------------
reset_state
: >"${WORK}/state/handshake"
export_env 3600
launch_up "${WORK}/up2.out"
if wait_for_file "${WORK}/run/ready" 60; then
  ok "a second up run publishes readiness"
else
  bad "a second up run did not publish readiness"
fi
awk '$0 == "-P OUTPUT DROP" { print "-P OUTPUT ACCEPT"; next } { print }' \
  "${WORK}/state/iptables" >"${WORK}/state/iptables.new"
mv "${WORK}/state/iptables.new" "${WORK}/state/iptables"
capture "${SH_BIN}" "${VPNCTL}" healthcheck
expect_rc 1 "healthcheck fails when an OUTPUT policy is not DROP"

TERM_PID=${UP_PID}
kill -TERM "${TERM_PID}" 2>/dev/null || true
if wait_for_exit "${TERM_PID}" 60; then
  ok "the supervisor stops on TERM"
else
  bad "the supervisor ignored TERM"
fi
term_rc=0
wait "${TERM_PID}" 2>/dev/null || term_rc=$?
UP_PID=''
if [ "${term_rc}" -eq 0 ]; then
  ok "TERM exits cleanly (exit 0)"
else
  bad "TERM must exit 0, got ${term_rc}"
fi
if [ -e "${WORK}/run/ready" ]; then
  bad "TERM must remove the readiness marker"
else
  ok "TERM removes the readiness marker and the runtime config"
fi
if grep -q '^default ' "${WORK}/state/routes" 2>/dev/null; then
  ok "TERM restores the default route for a same-namespace restart"
else
  bad "TERM left the namespace without a default route"
fi

# A host with IPv6 disabled: readiness must work and no v6 rule is written.
reset_state
: >"${WORK}/state/ip6tables"
export_env 3600
export VPN_NAMESPACE_IPV6=0
launch_up "${WORK}/noipv6.out"
if wait_for_file "${WORK}/run/ready" 60; then
  ok "an IPv4-only namespace becomes ready"
else
  bad "an IPv4-only namespace never became ready"
  sed -e 's/^/    /' "${WORK}/noipv6.out.err" >&2
fi
if [ -s "${WORK}/state/ip6tables" ]; then
  bad "IPv6 rules were written even though the namespace has no IPv6"
else
  ok "no IPv6 rule is written when the namespace has no IPv6"
fi
if grep -qx 'ipv6=absent' "${WORK}/run/ready" 2>/dev/null; then
  ok "the readiness marker records that IPv6 was absent"
else
  bad "the readiness marker does not record the IPv6 state"
fi
kill -TERM "${UP_PID}" 2>/dev/null || true
wait "${UP_PID}" 2>/dev/null || true
UP_PID=''
export VPN_NAMESPACE_IPV6=1

# ---------------------------------------------------------------------------
# 4. Failure injection: no readiness on any setup failure.
# ---------------------------------------------------------------------------
expect_up_fails() {
  exp_label="$1"
  reset_state
  launch_up "${WORK}/fail.out"
  if wait_for_exit "${UP_PID}" 300; then
    exp_rc=0
    wait "${UP_PID}" 2>/dev/null || exp_rc=$?
    UP_PID=''
    if [ "${exp_rc}" -ne 0 ]; then
      ok "${exp_label} fails (exit ${exp_rc})"
    else
      bad "${exp_label} must fail, got exit 0"
    fi
  else
    bad "${exp_label} never exited"
    cleanup_procs
  fi
  if [ -e "${WORK}/run/ready" ]; then
    bad "${exp_label} must not publish readiness"
  else
    ok "${exp_label} publishes no readiness marker"
  fi
  v4_open=0
  for exp_chain in INPUT OUTPUT FORWARD; do
    exp_pol=$(awk -v c="${exp_chain}" '$1 == "-P" && $2 == c { print $3 }' "${WORK}/state/iptables" 2>/dev/null | tail -1)
    [ "${exp_pol}" = "DROP" ] || v4_open=1
  done
  if [ "${v4_open}" = 0 ]; then
    ok "${exp_label} leaves the IPv4 filter closed"
  else
    bad "${exp_label} left the IPv4 filter open"
  fi
}

export_env 1
export STUB_FAIL_SETCONF=1
expect_up_fails "a rejected wg setconf"
export STUB_FAIL_SETCONF=0
export STUB_FAIL_LINK_ADD=1
expect_up_fails "a rejected interface creation"
export STUB_FAIL_LINK_ADD=0
export STUB_FAIL_RULE="-A INPUT -i ${EGRESS} -s ${ENDPOINT_IP} -p udp -j ACCEPT"
expect_up_fails "a rejected guard rule"
export STUB_FAIL_RULE=''

reset_state no-default
launch_up "${WORK}/nodefault.out"
if wait_for_exit "${UP_PID}" 300; then
  nd_rc=0
  wait "${UP_PID}" 2>/dev/null || nd_rc=$?
  UP_PID=''
  if [ "${nd_rc}" -ne 0 ]; then
    ok "no default route fails (exit ${nd_rc})"
  else
    bad "no default route must fail, got exit 0"
  fi
else
  bad "up never exited without a default route"
  cleanup_procs
fi
if grep -q -F "default route" "${WORK}/nodefault.out.err" 2>/dev/null; then
  ok "the missing default route is named"
else
  bad "the missing default route is not explained"
  sed -e 's/^/    /' "${WORK}/nodefault.out.err" >&2
fi

# ---------------------------------------------------------------------------
# 5. Endpoint handling: resolution read-back and the explicit override.
# ---------------------------------------------------------------------------
sed -e "s|^Endpoint = .*|Endpoint = vpn.example.test:51820|" \
  "${WORK}/client.conf" >"${WORK}/host-endpoint.conf"

reset_state
export_env 1
export VPN_CONFIG_FILE="${WORK}/host-endpoint.conf"
export STUB_WG_NO_ENDPOINT=1
launch_up "${WORK}/noendpoint.out"
if wait_for_exit "${UP_PID}" 300; then
  ne_rc=0
  wait "${UP_PID}" 2>/dev/null || ne_rc=$?
  UP_PID=''
  if [ "${ne_rc}" -ne 0 ]; then
    ok "an unresolvable endpoint fails (exit ${ne_rc})"
  else
    bad "an unresolvable endpoint must fail, got exit 0"
  fi
else
  bad "up never exited without a resolved endpoint"
  cleanup_procs
fi
if grep -q -F "VPN_ENDPOINT_IP" "${WORK}/noendpoint.out.err" 2>/dev/null; then
  ok "the failure is actionable and names VPN_ENDPOINT_IP"
else
  bad "the unresolved endpoint message does not mention VPN_ENDPOINT_IP"
  sed -e 's/^/    /' "${WORK}/noendpoint.out.err" >&2
fi
if [ -e "${WORK}/run/ready" ]; then
  bad "an unresolved endpoint must not publish readiness"
else
  ok "an unresolved endpoint publishes no readiness marker"
fi

export STUB_WG_NO_ENDPOINT=0
export VPN_ENDPOINT_IP=198.51.100.9
reset_state
launch_up "${WORK}/override.out"
if wait_for_file "${WORK}/run/ready" 60; then
  ok "up accepts an explicit VPN_ENDPOINT_IP for a hostname endpoint"
else
  bad "up did not reach readiness with VPN_ENDPOINT_IP"
fi
expect_file_contains "${WORK}/state/setconf.snapshot" "Endpoint = 198.51.100.9:51820" \
  "the setconf carries the overridden endpoint"
expect_present "ip route replace 198.51.100.9/32 via ${GATEWAY} dev ${EGRESS}"
expect_file_contains "${WORK}/run/ready" "endpoint_ip=198.51.100.9" \
  "the marker records the overridden endpoint"
kill -TERM "${UP_PID}" 2>/dev/null || true
observe_rc=0
wait "${UP_PID}" 2>/dev/null || observe_rc=$?
UP_PID=''
unset VPN_ENDPOINT_IP
export VPN_CONFIG_FILE="${WORK}/client.conf"

# ---------------------------------------------------------------------------
# 6. Input sources: base64 fallback and ambiguity.
# ---------------------------------------------------------------------------
B64="$(base64 <"${WORK}/client.conf" | tr -d '\n')"
set +e
OUT="$(env -u VPN_CONFIG_FILE VPS_NAME=vps-test LOKI_PUSH_URL="${LOKI}" \
  WG_CONFIG_BASE64="${B64}" VPN_RUN_DIR="${WORK}/run-b64" \
  "${SH_BIN}" "${VPNCTL}" check-config 2>"${WORK}/stderr")"
RC=$?
set -e
ERR="$(cat "${WORK}/stderr")"
expect_rc 0 "a base64-only configuration is accepted"
expect_out_contains "configuration ok" "base64 input resolves to the same plan"
if cmp -s "${WORK}/client.conf" "${WORK}/run-b64/wg0.conf"; then
  ok "the base64 configuration is decoded into the run directory"
else
  bad "the decoded configuration does not match the source"
fi
expect_mode "${WORK}/run-b64/wg0.conf" 600 "the decoded configuration is private"

set +e
OUT="$(env VPS_NAME=vps-test LOKI_PUSH_URL="${LOKI}" \
  VPN_CONFIG_FILE="${WORK}/client.conf" WG_CONFIG_BASE64="${B64}" \
  VPN_RUN_DIR="${WORK}/run-b64" "${SH_BIN}" "${VPNCTL}" check-config 2>"${WORK}/stderr")"
RC=$?
set -e
ERR="$(cat "${WORK}/stderr")"
expect_rc 2 "file plus base64 input is rejected"
expect_err_contains "ambiguous" "simultaneous inputs are reported as ambiguous"

# ---------------------------------------------------------------------------
# 7. Host NIC counters are produced while `up` supervises (loop is spawned).
# ---------------------------------------------------------------------------
if [ -f "${WORK}/textfile/hostnet.prom" ]; then
  ok "the supervisor spawned hostnet-loop"
else
  bad "up did not spawn hostnet-loop"
fi

finish
