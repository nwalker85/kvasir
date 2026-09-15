#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
export XDG_STATE_HOME="${TMP}/state"

# shellcheck disable=SC1091
source "${ROOT}/lib/common.sh"
# shellcheck disable=SC1091
source "${ROOT}/lib/receipt.sh"

command -v jq >/dev/null 2>&1 || { printf 'skip - jq not installed\n'; exit 0; }

receipt::write "enr-1" '{"id":"enr-1","class":"host","principal":"grani"}' >/dev/null
got="$(receipt::get enr-1)"
echo "$got" | jq -e '.id == "enr-1"' >/dev/null

if ( receipt::write "enr-bad" '{"id":"x","join_token":"nope"}' >/dev/null 2>&1 ); then
  printf 'FAIL: secret-bearing receipt was accepted\n' >&2
  exit 1
fi

printf 'ok - receipt redaction\n'
