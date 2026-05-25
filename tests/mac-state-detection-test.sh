#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
STUB_DIR="${TMPDIR}/bin"
mkdir -p "${STUB_DIR}"
trap 'rm -rf "${TMPDIR}"' EXIT

# ssh stub — behavior controlled by KVASIR_TEST_STATE env var
cat >"${STUB_DIR}/ssh" <<'STUB'
#!/usr/bin/env bash
state="${KVASIR_TEST_STATE:-clean}"
case "$state" in
  clean)
    exit 1
    ;;
  fully-enrolled)
    if [[ "$*" == *"test -f /etc/krb5.keytab"* ]]; then
      exit 0
    elif [[ "$*" == *"test -f /Library/Preferences/OpenDirectory"* ]]; then
      exit 0
    elif [[ "$*" == *"test -f /etc/sudoers.d/kvasir-managed-"* ]]; then
      exit 0
    fi
    exit 1
    ;;
  partial-keytab-only)
    if [[ "$*" == *"test -f /etc/krb5.keytab"* ]]; then
      exit 0
    fi
    exit 1
    ;;
esac
exit 1
STUB
chmod +x "${STUB_DIR}/ssh"

export PATH="${STUB_DIR}:${PATH}"
source "${ROOT}/lib/common.sh"
source "${ROOT}/lib/mac.sh"

# Expected returns: 0=refresh, 1=clean install, 2=partial
test::should_refresh::clean_returns_1() {
  export KVASIR_TEST_STATE=clean
  local rc=0
  mac::_should_refresh "odin" "odin.ravenhelm.dev" || rc=$?
  if (( rc != 1 )); then
    printf 'FAIL: expected rc=1 for clean state, got %d\n' "$rc" >&2
    return 1
  fi
  printf 'PASS: should_refresh::clean_returns_1\n'
}

test::should_refresh::fully_enrolled_returns_0() {
  export KVASIR_TEST_STATE=fully-enrolled
  local rc=0
  mac::_should_refresh "odin" "odin.ravenhelm.dev" || rc=$?
  if (( rc != 0 )); then
    printf 'FAIL: expected rc=0 for fully-enrolled, got %d\n' "$rc" >&2
    return 1
  fi
  printf 'PASS: should_refresh::fully_enrolled_returns_0\n'
}

test::should_refresh::partial_returns_2() {
  export KVASIR_TEST_STATE=partial-keytab-only
  local rc=0
  mac::_should_refresh "odin" "odin.ravenhelm.dev" || rc=$?
  if (( rc != 2 )); then
    printf 'FAIL: expected rc=2 for partial state, got %d\n' "$rc" >&2
    return 1
  fi
  printf 'PASS: should_refresh::partial_returns_2\n'
}

test::should_refresh::clean_returns_1
test::should_refresh::fully_enrolled_returns_0
test::should_refresh::partial_returns_2
