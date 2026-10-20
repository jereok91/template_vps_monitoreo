#!/usr/bin/env bash
#
# Shared helpers for the deterministic test suite.
#
# Every test runs entirely on temporary fixtures with fake key material and stubbed
# network commands. Nothing here touches the host network, Docker, or a real server.
#
#   bash tests/run.sh            # run all tests

PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); printf '  ok: %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL: %s\n' "$1"; }

# Creates a scratch directory outside the repository and exports WORK.
mkwork() {
  WORK="$(mktemp -d "/tmp/vpn-${1}.XXXXXX")"
  case "${WORK}" in
    "$(cd "$(dirname "$0")/.." && pwd)"/*)
      echo "refusing to use a scratch directory inside the repository: ${WORK}" >&2
      exit 1
      ;;
  esac
  trap 'rm -rf "${WORK}"' EXIT
  export WORK
}

# A structurally valid 44-character WireGuard key (base64 of 32 identical bytes).
# It is NOT a real key: the seed character makes every fixture key different.
mkkey() {
  head -c 32 /dev/zero | tr '\0' "$1" | base64 | tr -d '\n'
}

file_mode() {
  if stat -c %a "$1" >/dev/null 2>&1; then
    stat -c %a "$1"
  else
    stat -f %Lp "$1"
  fi
}

# Runs a command, capturing stdout/stderr/exit code in OUT/ERR/RC.
capture() {
  set +e
  OUT="$("$@" 2>"${WORK}/stderr")"
  RC=$?
  set -e
  ERR="$(cat "${WORK}/stderr")"
}

expect_rc() {
  if [ "${RC}" = "$1" ]; then
    ok "$2 (exit ${RC})"
  else
    bad "$2 (expected exit $1, got ${RC})"
    printf '    stdout: %s\n    stderr: %s\n' "${OUT}" "${ERR}" >&2
  fi
}

expect_err_contains() {
  case "${ERR}" in
    *"$1"*) ok "$2" ;;
    *) bad "$2 (stderr lacks '$1')"; printf '    stderr: %s\n' "${ERR}" >&2 ;;
  esac
}

expect_out_contains() {
  case "${OUT}" in
    *"$1"*) ok "$2" ;;
    *) bad "$2 (stdout lacks '$1')"; printf '    stdout: %s\n' "${OUT}" >&2 ;;
  esac
}

expect_err_not_contains() {
  case "${ERR}" in
    *"$1"*) bad "$2 (stderr leaks '$1')" ;;
    *) ok "$2" ;;
  esac
}

expect_out_not_contains() {
  case "${OUT}" in
    *"$1"*) bad "$2 (stdout leaks '$1')" ;;
    *) ok "$2" ;;
  esac
}

finish() {
  printf '\n%d passed, %d failed\n' "${PASS}" "${FAIL}"
  [ "${FAIL}" -eq 0 ]
}
