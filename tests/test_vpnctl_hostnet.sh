#!/usr/bin/env bash
#
# hostnet-loop: host NIC counters for node_exporter's textfile collector.
#
# The source fixture mimics /proc/1/net/dev of the host network namespace. Nothing
# here reads the real host /proc or touches a real interface.
#
#   bash tests/test_vpnctl_hostnet.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VPNCTL="${REPO_ROOT}/files/vpnctl"
SH_BIN="${SH_BIN:-/bin/sh}"

# shellcheck source=tests/lib.sh
. "${REPO_ROOT}/tests/lib.sh"
mkwork hostnet

PRIV="$(mkkey P)"
PUB="$(mkkey U)"
PSK="$(mkkey S)"
HUB="10.77.0.1"
PEER="10.77.0.2"
ENDPOINT_IP="203.0.113.10"
GATEWAY="192.0.2.1"
EGRESS="eth9"
LOKI="http://${HUB}:3100/loki/api/v1/push"

PROC_OK="${WORK}/proc"
TEXTFILE="${WORK}/textfile"
PROM="${TEXTFILE}/hostnet.prom"

mkdir -p "${PROC_OK}/1/net" "${TEXTFILE}" "${WORK}/bin" "${WORK}/state"

cat >"${PROC_OK}/1/net/dev" <<'EOF'
Inter-|   Receive                                                |  Transmit
 face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
    lo:    1500      10    1    2    3     4          5         6     2500      20    7    8    9    10      11         12
  eth0:  111213     100    0    0    0     0          0         0   333435     200    0    0    0     0       0          0
EOF

# run_once <host-proc> [textfile-dir]
run_once() {
  rh_proc="$1"
  rh_dir="${2:-${TEXTFILE}}"
  set +e
  OUT="$(VPN_HOSTNET_ONCE=1 VPN_HOST_PROC="${rh_proc}" VPN_TEXTFILE_DIR="${rh_dir}" \
    "${SH_BIN}" "${VPNCTL}" hostnet-loop 2>"${WORK}/stderr")"
  RC=$?
  ERR="$(cat "${WORK}/stderr")"
}

expect_prom_line() {
  if grep -q -F -x -- "$1" "${PROM}" 2>/dev/null; then
    ok "metric line: $1"
  else
    bad "missing metric line: $1"
  fi
}

expect_prom_type() {
  if grep -q -F -x -- "# TYPE $1 counter" "${PROM}" 2>/dev/null; then
    ok "counter type declared for $1"
  else
    bad "no '# TYPE $1 counter' line"
  fi
}

# ---------------------------------------------------------------------------
# 1. One emission from a readable host fixture.
# ---------------------------------------------------------------------------
run_once "${PROC_OK}"
expect_rc 0 "hostnet-loop exits 0 after a single emission"
if [ -f "${PROM}" ]; then
  ok "hostnet.prom is written"
else
  bad "hostnet.prom was not written"
fi

expect_prom_line "hostnet_metrics_available 1"
if grep -q -F -x -- "# TYPE hostnet_metrics_available gauge" "${PROM}" 2>/dev/null; then
  ok "availability metric declares HELP/TYPE"
else
  bad "availability metric has no TYPE line"
fi
if grep -q -F -x -- "# HELP hostnet_metrics_available 1 when host NIC counters were read from the host network namespace." "${PROM}" 2>/dev/null; then
  ok "availability metric declares HELP"
else
  bad "availability metric has no HELP line"
fi
if grep -q -E -x -- "hostnet_last_read_timestamp_seconds [0-9]+" "${PROM}" 2>/dev/null; then
  ok "the read timestamp is numeric"
else
  bad "the read timestamp is missing or non-numeric"
fi

for metric in \
  node_network_receive_bytes_total \
  node_network_receive_packets_total \
  node_network_receive_errs_total \
  node_network_receive_drop_total \
  node_network_receive_fifo_total \
  node_network_receive_frame_total \
  node_network_receive_compressed_total \
  node_network_receive_multicast_total \
  node_network_transmit_bytes_total \
  node_network_transmit_packets_total \
  node_network_transmit_errs_total \
  node_network_transmit_drop_total \
  node_network_transmit_fifo_total \
  node_network_transmit_colls_total \
  node_network_transmit_carrier_total \
  node_network_transmit_compressed_total; do
  expect_prom_type "${metric}"
done

expect_prom_line 'node_network_receive_bytes_total{device="lo",source="hostnet"} 1500'
expect_prom_line 'node_network_receive_packets_total{device="lo",source="hostnet"} 10'
expect_prom_line 'node_network_receive_errs_total{device="lo",source="hostnet"} 1'
expect_prom_line 'node_network_receive_drop_total{device="lo",source="hostnet"} 2'
expect_prom_line 'node_network_receive_fifo_total{device="lo",source="hostnet"} 3'
expect_prom_line 'node_network_receive_frame_total{device="lo",source="hostnet"} 4'
expect_prom_line 'node_network_receive_compressed_total{device="lo",source="hostnet"} 5'
expect_prom_line 'node_network_receive_multicast_total{device="lo",source="hostnet"} 6'
expect_prom_line 'node_network_transmit_bytes_total{device="lo",source="hostnet"} 2500'
expect_prom_line 'node_network_transmit_packets_total{device="lo",source="hostnet"} 20'
expect_prom_line 'node_network_transmit_errs_total{device="lo",source="hostnet"} 7'
expect_prom_line 'node_network_transmit_drop_total{device="lo",source="hostnet"} 8'
expect_prom_line 'node_network_transmit_fifo_total{device="lo",source="hostnet"} 9'
expect_prom_line 'node_network_transmit_colls_total{device="lo",source="hostnet"} 10'
expect_prom_line 'node_network_transmit_carrier_total{device="lo",source="hostnet"} 11'
expect_prom_line 'node_network_transmit_compressed_total{device="lo",source="hostnet"} 12'
expect_prom_line 'node_network_receive_bytes_total{device="eth0",source="hostnet"} 111213'
expect_prom_line 'node_network_receive_errs_total{device="eth0",source="hostnet"} 0'
expect_prom_line 'node_network_transmit_bytes_total{device="eth0",source="hostnet"} 333435'
expect_prom_line 'node_network_transmit_compressed_total{device="eth0",source="hostnet"} 0'

value_lines=$(grep -c -E '^node_network_(receive|transmit)_[a-z]+_total[{]device=' "${PROM}" 2>/dev/null || printf 0)
if [ "${value_lines}" = 32 ]; then
  ok "two devices produce exactly 16 counters each"
else
  bad "expected 32 counter lines, got ${value_lines}"
fi
if awk '/^node_network_/ && $0 !~ /^node_network_(receive|transmit)_[a-z]+_total[{]device="[A-Za-z0-9_.:-]+",source="hostnet"[}] [0-9]+$/ { bad = 1 } END { exit(bad ? 1 : 0) }' "${PROM}"; then
  ok "every counter line carries both labels and a numeric value"
else
  bad "a counter line is missing its device/source labels or a numeric value"
fi
if awk '/^node_network_/ && $NF !~ /^[0-9]+$/ { exit 1 }' "${PROM}"; then
  ok "every exported counter value is an integer"
else
  bad "a counter value is not an integer"
fi
prom_mode="$(file_mode "${PROM}" 2>/dev/null || printf 'missing')"
if [ "${prom_mode}" = 644 ]; then
  ok "hostnet.prom is world readable for node_exporter (mode ${prom_mode})"
else
  bad "hostnet.prom must be mode 644, got ${prom_mode}"
fi

# ---------------------------------------------------------------------------
# 2. Repeated runs never leave a partial file behind.
# ---------------------------------------------------------------------------
run_once "${PROC_OK}"
expect_rc 0 "a second emission succeeds"
leftovers=$(ls -A "${TEXTFILE}" | grep -v -x -E 'hostnet\.prom' | wc -l | tr -d ' ')
if [ "${leftovers}" = 0 ]; then
  ok "no temporary or partial file remains in the textfile directory"
else
  bad "leftover files in the textfile directory"
  ls -A "${TEXTFILE}" >&2
fi
prom_count=$(ls -A "${TEXTFILE}" | wc -l | tr -d ' ')
if [ "${prom_count}" = 1 ]; then
  ok "exactly one textfile is published"
else
  bad "expected a single textfile, found ${prom_count}"
fi

# ---------------------------------------------------------------------------
# 3. Devices whose name is not a sane interface name are skipped.
# ---------------------------------------------------------------------------
PROC_BAD="${WORK}/proc-bad"
mkdir -p "${PROC_BAD}/1/net"
cat >"${PROC_BAD}/1/net/dev" <<'EOF'
Inter-|   Receive                                                |  Transmit
 face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
    lo:     100       1    0    0    0     0          0         0      200       2    0    0    0     0       0          0
bad dev:     300       3    0    0    0     0          0         0      400       4    0    0    0     0       0          0
  ev"il:     500       5    0    0    0     0          0         0      600       6    0    0    0     0       0          0
EOF
run_once "${PROC_BAD}"
expect_rc 0 "a fixture with bad device names still succeeds"
if grep -q -F 'device="bad dev"' "${PROM}" 2>/dev/null; then
  bad "a device name with a space was exported"
else
  ok "a device name with a space is skipped"
fi
if grep -q -F 'device="ev"il"' "${PROM}" 2>/dev/null; then
  bad "a device name with a quote was exported"
else
  ok "a device name with a quote is skipped"
fi
expect_prom_line 'node_network_receive_bytes_total{device="lo",source="hostnet"} 100'
bad_lines=$(grep -c -E '^node_network_' "${PROM}" 2>/dev/null || printf 0)
if [ "${bad_lines}" = 16 ]; then
  ok "only the valid device is exported (16 counters)"
else
  bad "expected 16 counter lines for one device, got ${bad_lines}"
fi

# ---------------------------------------------------------------------------
# 4. Missing or unreadable source: availability 0, no wrong data, exit 0.
# ---------------------------------------------------------------------------
run_once "${WORK}/nonexistent-proc"
expect_rc 0 "a missing host /proc still exits 0"
expect_prom_line "hostnet_metrics_available 0"
if grep -q -E '^node_network_' "${PROM}" 2>/dev/null; then
  bad "device counters were emitted without a readable source"
else
  ok "no device counter is emitted without a readable source"
fi
if grep -q -E -x -- "hostnet_last_read_timestamp_seconds [0-9]+" "${PROM}" 2>/dev/null; then
  ok "the read attempt is still timestamped"
else
  bad "no timestamp on an unavailable read"
fi

PROC_UNREADABLE="${WORK}/proc-unreadable"
mkdir -p "${PROC_UNREADABLE}/1/net"
cp "${PROC_OK}/1/net/dev" "${PROC_UNREADABLE}/1/net/dev"
chmod 000 "${PROC_UNREADABLE}/1/net/dev" 2>/dev/null || true
if [ "$(id -u)" = 0 ]; then
  ok "skipped the unreadable-source check: running as root, mode 000 is still readable"
else
  run_once "${PROC_UNREADABLE}"
  expect_rc 0 "an unreadable host /proc still exits 0"
  expect_prom_line "hostnet_metrics_available 0"
  if grep -q -E '^node_network_' "${PROM}" 2>/dev/null; then
    bad "device counters were emitted from an unreadable source"
  else
    ok "no device counter is emitted from an unreadable source"
  fi
fi

# ---------------------------------------------------------------------------
# 5. `up` spawns the loop, so the textfile appears without extra plumbing.
# ---------------------------------------------------------------------------
cat >"${WORK}/bin/ip" <<'STUB'
#!/bin/sh
state="${STUB_STATE:?}"
case "${1:-} ${2:-}" in
  "route show")
    if [ "${3:-}" = default ]; then
      if [ "$(cat "$state/default" 2>/dev/null)" = gone ]; then
        exit 0
      fi
      printf 'default via 192.0.2.1 dev eth9 proto static\n'
    else
      cat "$state/routes" 2>/dev/null
    fi
    ;;
  "route replace")
    entry=${3:-}
    shift 3
    for a in "$@"; do entry="${entry} $a"; done
    printf '%s\n' "$entry" >>"$state/routes"
    ;;
  "route del")
    if [ "${3:-}" = default ]; then printf 'gone\n' >"$state/default"; fi
    ;;
  "link show")
    if [ "${4:-}" = wg0 ]; then exit 0; fi
    exit 1
    ;;
  "link add"|"link del"|"link set"|"addr add"|"addr show") exit 0 ;;
esac
exit 0
STUB
cat >"${WORK}/bin/wg" <<'STUB'
#!/bin/sh
state="${STUB_STATE:?}"
case "${1:-} ${3:-}" in
  "setconf "*) cp "${3:-}" "$state/setconf" 2>/dev/null || true ;;
  "show endpoints")
    ep=$(awk '$1 == "Endpoint" { print $3; exit }' "$state/setconf" 2>/dev/null)
    printf 'peerkey\t%s\n' "${ep:-203.0.113.10:51820}"
    ;;
esac
exit 0
STUB
cat >"${WORK}/bin/iptables" <<'STUB'
#!/bin/sh
case "${1:-}" in
  -S) printf '%s %s %s\n' -P "${2:-INPUT}" DROP ;;
  -C) exit 0 ;;
esac
exit 0
STUB
chmod +x "${WORK}/bin/ip" "${WORK}/bin/wg" "${WORK}/bin/iptables"

# ip6tables is the same stub with its own state file: the runtime guard locks
# IPv6 down too, even though the tunnel only carries IPv4.
sed -e "s|'iptables %s|'ip6tables %s|" -e 's|^db="$state/iptables"|db="$state/ip6tables"|' \
  "${WORK}/bin/iptables" >"${WORK}/bin/ip6tables"
chmod +x "${WORK}/bin/ip6tables"

# Route state for the super-simple ip stub above.
mkdir -p "${WORK}/state"
printf 'default via 192.0.2.1 dev eth9 proto static\n' >"${WORK}/state/routes"
printf 'present\n' >"${WORK}/state/default"

cat >"${WORK}/client.conf" <<EOF
[Interface]
Address = ${PEER}/24
PrivateKey = ${PRIV}
ListenPort = 51820

[Peer]
PublicKey = ${PUB}
PresharedKey = ${PSK}
AllowedIPs = ${HUB}/32
Endpoint = ${ENDPOINT_IP}:51820
PersistentKeepalive = 25
EOF

UP_TEXTFILE="${WORK}/textfile-up"
mkdir -p "${UP_TEXTFILE}"

export VPS_NAME=vps-test
export LOKI_PUSH_URL="${LOKI}"
export VPN_CONFIG_FILE="${WORK}/client.conf"
export VPN_RUN_DIR="${WORK}/run-up"
export VPN_TEXTFILE_DIR="${UP_TEXTFILE}"
export VPN_HOST_PROC="${PROC_OK}"
export VPN_HOSTNET_INTERVAL=15
export VPN_SUPERVISE_INTERVAL=2
export STUB_STATE="${WORK}/state"
export PATH="${WORK}/bin:${PATH}"
unset VPN_HOSTNET_ONCE 2>/dev/null || true

(exec "${SH_BIN}" "${VPNCTL}" up >"${WORK}/up.out" 2>"${WORK}/up.out.err") &
UP_PID=$!

up_i=0
while [ ! -f "${UP_TEXTFILE}/hostnet.prom" ]; do
  up_i=$((up_i + 1))
  if [ "${up_i}" -gt 60 ]; then break; fi
  sleep 0.1
done

if [ -f "${UP_TEXTFILE}/hostnet.prom" ]; then
  ok "up spawns hostnet-loop and the textfile appears"
  if grep -q -F -x -- "hostnet_metrics_available 1" "${UP_TEXTFILE}/hostnet.prom"; then
    ok "the spawned loop reads the host fixture"
  else
    bad "the spawned loop did not export the host fixture"
  fi
else
  bad "up did not create ${UP_TEXTFILE}/hostnet.prom"
  sed -e 's/^/    /' "${WORK}/up.out.err" >&2
fi

kill -TERM "${UP_PID}" 2>/dev/null || true
wait_i=0
while kill -0 "${UP_PID}" 2>/dev/null; do
  wait_i=$((wait_i + 1))
  if [ "${wait_i}" -gt 60 ]; then break; fi
  sleep 0.1
done
up_rc=0
wait "${UP_PID}" 2>/dev/null || up_rc=$?
if [ "${up_rc}" -eq 0 ]; then
  ok "the supervised up stops on TERM (exit 0)"
else
  bad "TERM did not stop up cleanly (exit ${up_rc})"
fi

finish
