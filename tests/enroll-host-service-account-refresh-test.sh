#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! grep -Fq 'kanidm::host_create' "${ROOT}/bin/enroll-host"; then
  printf 'FAIL: enroll-host does not invoke kanidm::host_create\n' >&2
  exit 1
fi

if ! grep -Fq 'fleetdm::enroll_host' "${ROOT}/bin/enroll-host"; then
  printf 'FAIL: enroll-host does not invoke fleetdm::enroll_host\n' >&2
  exit 1
fi

printf 'PASS: enroll-host modern enrollment handles Kanidm and FleetDM\n'

