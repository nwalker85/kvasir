#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

CALLS="${TMPDIR}/ipa-calls"

export KVASIR_DRY_RUN=0
export KVASIR_LOG_LEVEL=error
# shellcheck disable=SC1091
source "${ROOT}/lib/common.sh"
# shellcheck disable=SC1091
source "${ROOT}/lib/freeipa.sh"

ipa::cmd() {
  printf '%s\n' "$*" >>"${CALLS}"
  case "$1" in
    sudorule-show) return 0 ;;
    *) return 0 ;;
  esac
}

ipa::service_account_bootstrap_root_sudo \
  "kvasir-root-grani" \
  "svc-grani-root" \
  "grani.ravenhelm.dev"

grep -Fxq 'sudorule-add-host kvasir-root-grani --hosts=grani.ravenhelm.dev' "${CALLS}"
if grep -Fq -- '--host=grani.ravenhelm.dev' "${CALLS}"; then
  printf 'not ok - sudorule host flag used singular --host\n' >&2
  exit 1
fi

printf 'ok - freeipa sudo rule host flag\n'
