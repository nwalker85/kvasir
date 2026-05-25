#!/usr/bin/env bash
# Integration test for macOS enrollment.
#
# Gated by KVASIR_INTEGRATION_TARGET. If unset, exits 0 (skipped).
# If set, runs dry-run + optional --apply + post-state validation +
# uninstall against that target.
#
# REQUIREMENTS for the target:
#   - SSH reachable
#   - macOS (uname -s = Darwin)
#   - SSH user has NOPASSWD sudo (or KVASIR_SUDO_PASSWORD_OP set)
#   - You can afford to reset its FreeIPA state
#
# Usage:
#   KVASIR_INTEGRATION_TARGET=odin bash tests/mac-enroll-host-integration-test.sh
#   KVASIR_INTEGRATION_TARGET=odin KVASIR_INTEGRATION_APPLY=1 bash tests/...
set -euo pipefail

if [[ -z "${KVASIR_INTEGRATION_TARGET:-}" ]]; then
  printf 'SKIP: set KVASIR_INTEGRATION_TARGET to run\n'
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${KVASIR_INTEGRATION_TARGET}"

printf '=== dry-run against %s ===\n' "$TARGET"
"${ROOT}/bin/kvasir" enroll-host "$TARGET" 2>&1 | tee /tmp/kvasir-int-dryrun.log
grep -q '\[mac 1/10\]' /tmp/kvasir-int-dryrun.log \
  || { printf 'FAIL: dry-run did not enter macOS path\n' >&2; exit 1; }
grep -q '\[mac 10/10\]' /tmp/kvasir-int-dryrun.log \
  || { printf 'FAIL: dry-run did not reach step 10\n' >&2; exit 1; }
printf 'PASS: dry-run exercises all 10 mac steps\n'

if [[ "${KVASIR_INTEGRATION_APPLY:-0}" != "1" ]]; then
  printf 'SKIP: set KVASIR_INTEGRATION_APPLY=1 to actually apply\n'
  exit 0
fi

printf '=== apply against %s ===\n' "$TARGET"
"${ROOT}/bin/kvasir" enroll-host "$TARGET" --apply 2>&1 | tee /tmp/kvasir-int-apply.log
grep -q 'DONE' /tmp/kvasir-int-apply.log \
  || { printf 'FAIL: apply did not complete\n' >&2; exit 1; }

printf '=== post-state validation ===\n'
ssh "$TARGET" 'id nwalker' >/dev/null \
  || { printf 'FAIL: id nwalker fails post-apply\n' >&2; exit 1; }
printf 'PASS: id nwalker resolves\n'

ssh "$TARGET" 'sudo klist -k /etc/krb5.keytab 2>/dev/null | grep -q host/' \
  || { printf 'FAIL: host principal missing from keytab\n' >&2; exit 1; }
printf 'PASS: host principal in keytab\n'

# sudo -n requires the test runner to be nwalker on the target — skip if not
if ssh "$TARGET" 'whoami' | grep -q nwalker; then
  ssh "$TARGET" 'sudo -n true' \
    || { printf 'FAIL: nwalker sudo -n true failed\n' >&2; exit 1; }
  printf 'PASS: nwalker has NOPASSWD sudo\n'
else
  printf 'SKIP: SSH user is not nwalker; cannot test sudo grant from this side\n'
fi

printf '=== uninstall + re-validate clean ===\n'
"${ROOT}/bin/kvasir" enroll-host "$TARGET" 2>&1 >/dev/null  # dry-run baseline
source "${ROOT}/lib/common.sh"
source "${ROOT}/lib/op.sh"
source "${ROOT}/lib/freeipa.sh"
source "${ROOT}/lib/mac.sh"
kvasir::load_env
KVASIR_DRY_RUN=0 mac::uninstall "$TARGET" "${TARGET%%.*}"

ssh "$TARGET" 'id nwalker' >/dev/null 2>&1 \
  && { printf 'FAIL: id nwalker still resolves after uninstall\n' >&2; exit 1; }
printf 'PASS: id nwalker fails post-uninstall (clean state)\n'

printf '\nAll integration checks passed.\n'
