#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/lib/common.sh"
# shellcheck disable=SC1091
source "${ROOT}/lib/pki.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[[ "$(pki::authority_for user)" == dogtag ]] || fail "user -> dogtag"
[[ "$(pki::authority_for host)" == dogtag ]] || fail "host -> dogtag"
[[ "$(pki::authority_for service)" == dogtag ]] || fail "service -> dogtag"
[[ "$(pki::authority_for endpoint)" == step-ca ]] || fail "endpoint -> step-ca"
[[ "$(pki::authority_for workload)" == spire ]] || fail "workload -> spire"
[[ "$(pki::spiffe_id audio-app/foo)" == "spiffe://ravenhelm.dev/audio-app/foo" ]] \
  || fail "spiffe id"

if ( pki::authority_for widget >/dev/null 2>&1 ); then
  fail "unknown class should die"
fi

printf 'ok - pki authority routing\n'
