#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAST_COMMAND="$(
  awk 'NF && $1 !~ /^#/ { command=$0 } END { print command }' \
    "${ROOT}/bin/enroll-host"
)"

if [[ "${LAST_COMMAND}" != "exit 0" ]]; then
  printf 'FAIL: successful apply can inherit the false dry-run predicate: %s\n' \
    "${LAST_COMMAND}" >&2
  exit 1
fi

printf 'PASS: enroll-host success terminates with status zero\n'
