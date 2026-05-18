#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
STUB_DIR="${TMPDIR}/bin"
mkdir -p "${STUB_DIR}"
trap 'rm -rf "${TMPDIR}"' EXIT

cat >"${STUB_DIR}/op" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

case "$*" in
  item\ get*)
    exit 1
    ;;
  item\ create*)
    printf '%s\n' "$@" >"${KVASIR_TEST_OP_ARGS}"
    exit 0
    ;;
  *)
    printf 'unexpected op args: %s\n' "$*" >&2
    exit 64
    ;;
esac
STUB
chmod +x "${STUB_DIR}/op"

OP_ARGS="${TMPDIR}/op.args"
PATH="${STUB_DIR}:$PATH" \
  KVASIR_TEST_OP_ARGS="${OP_ARGS}" \
  KVASIR_DRY_RUN=0 \
  KVASIR_LOG_LEVEL=error \
  bash -c "
    source '${ROOT}/lib/common.sh'
    source '${ROOT}/lib/op.sh'
    op::create_item 'Example' ravenmask 'username=svc-example-root' 'concealed:password=secret-value'
  "

grep -Fxq 'password[password]=secret-value' "${OP_ARGS}"
if grep -Fxq 'password=secret-value[password]' "${OP_ARGS}"; then
  printf 'not ok - concealed field type was appended to the value\n' >&2
  exit 1
fi

printf 'ok - op create item concealed fields\n'
