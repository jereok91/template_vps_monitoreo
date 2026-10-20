#!/usr/bin/env bash
#
# Deterministic test runner for this template.
#
# Runs every tests/test_*.sh in sorted (stable) order, prints each file name, keeps
# going after a failing suite so one run shows every problem, and exits non-zero if
# any suite failed. No Docker daemon, no network and no key material is required:
# test_compose_contract.sh skips itself when the Docker CLI is absent.
#
#   bash tests/run.sh

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ ! -d "${TESTS_DIR}" ]; then
  printf 'run.sh: tests directory not found: %s\n' "${TESTS_DIR}" >&2
  exit 2
fi

# Sorted by file name: the order is deterministic and independent of the filesystem.
# The list is rebuilt on every run, so a new tests/test_*.sh is picked up for free.
SUITES="$(find "${TESTS_DIR}" -maxdepth 1 -type f -name 'test_*.sh' | sort)"

if [ -z "${SUITES}" ]; then
  printf 'run.sh: no tests/test_*.sh found in %s\n' "${TESTS_DIR}" >&2
  exit 2
fi

printf 'Running every suite under %s\n\n' "${TESTS_DIR}"

RAN=0
FAILED=0
FAILED_NAMES=''

while IFS= read -r suite; do
  [ -n "${suite}" ] || continue
  name="${suite##*/}"
  RAN=$((RAN + 1))
  printf '=== %s ===\n' "${name}"
  if bash "${suite}"; then
    printf -- '--- %s: PASS ---\n\n' "${name}"
  else
    rc=$?
    FAILED=$((FAILED + 1))
    FAILED_NAMES="${FAILED_NAMES} ${name}"
    printf -- '--- %s: FAIL (exit %s) ---\n\n' "${name}" "${rc}"
  fi
done <<EOF
${SUITES}
EOF

if [ "${FAILED}" -ne 0 ]; then
  printf '%d/%d suites passed, %d failed:%s\n' \
    "$((RAN - FAILED))" "${RAN}" "${FAILED}" "${FAILED_NAMES}"
  exit 1
fi

printf '%d/%d suites passed\n' "${RAN}" "${RAN}"
exit 0
