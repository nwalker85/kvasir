#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STEP_EIGHT="$(
  awk '
    /# ---------- 8\. Root-capable service account/ { capture=1 }
    /# ---------- 9\. Save record/ { capture=0 }
    capture { print }
  ' "${ROOT}/bin/enroll-host"
)"

# shellcheck disable=SC2016
if ! grep -Fq 'kvasir::run_ssh_sudo "${SSH_HOST}" "systemctl restart sssd"' \
  <<<"${STEP_EIGHT}"; then
  printf 'FAIL: enroll-host does not refresh SSSD after creating sudo policy\n' >&2
  exit 1
fi

printf 'PASS: enroll-host refreshes SSSD after creating sudo policy\n'
