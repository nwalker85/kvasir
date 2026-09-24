#!/usr/bin/env bash
# Tests for T9b: Kvasir modernizer (Kanidm + FleetDM + Draupnir)

set -euo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
KVASIR_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

echo "=== Testing T9b: Kvasir Modernizer ==="

# 1. Test enroll-host dry-run
echo "Testing enroll-host..."
HOST_OUTPUT="$("${KVASIR_ROOT}/bin/enroll-host" test-node-99 2>&1)"
echo "${HOST_OUTPUT}"

# Verify no FreeIPA or Dogtag references
if echo "${HOST_OUTPUT}" | grep -iqE "freeipa|dogtag"; then
  echo "FAIL: enroll-host output contains FreeIPA or Dogtag reference!"
  exit 1
fi

# Verify Kanidm, FleetDM, and Draupnir are all present
echo "${HOST_OUTPUT}" | grep -q "Kanidm" || { echo "FAIL: missing Kanidm in enroll-host"; exit 1; }
echo "${HOST_OUTPUT}" | grep -q "FleetDM" || { echo "FAIL: missing FleetDM in enroll-host"; exit 1; }
echo "${HOST_OUTPUT}" | grep -q "Draupnir" || { echo "FAIL: missing Draupnir in enroll-host"; exit 1; }
echo "ok - enroll-host verified without FreeIPA/Dogtag references"

# 2. Test enroll-user dry-run
echo "Testing enroll-user..."
USER_OUTPUT="$("${KVASIR_ROOT}/bin/enroll-user" modernuser modernuser@ravenmask.net --first Modern --last User 2>&1)"
echo "${USER_OUTPUT}"

if echo "${USER_OUTPUT}" | grep -iqE "freeipa|zitadel"; then
  echo "FAIL: enroll-user output contains FreeIPA or Zitadel reference!"
  exit 1
fi

echo "${USER_OUTPUT}" | grep -q "Kanidm" || { echo "FAIL: missing Kanidm in enroll-user"; exit 1; }
echo "${USER_OUTPUT}" | grep -q "Keycloak" || { echo "FAIL: missing Keycloak in enroll-user"; exit 1; }
echo "ok - enroll-user verified without FreeIPA/Zitadel references"

# 3. Test add-ssh-key dry-run
echo "Testing add-ssh-key..."
SSH_OUTPUT="$("${KVASIR_ROOT}/bin/add-ssh-key" --user modernuser 2>&1)"
echo "${SSH_OUTPUT}"

if echo "${SSH_OUTPUT}" | grep -iqE "freeipa"; then
  echo "FAIL: add-ssh-key output contains FreeIPA reference!"
  exit 1
fi

echo "${SSH_OUTPUT}" | grep -q "Kanidm" || { echo "FAIL: missing Kanidm in add-ssh-key"; exit 1; }
echo "${SSH_OUTPUT}" | grep -q "Draupnir" || { echo "FAIL: missing Draupnir in add-ssh-key"; exit 1; }
echo "ok - add-ssh-key verified without FreeIPA references"

echo "=== All T9b acceptance tests passed successfully! ==="
