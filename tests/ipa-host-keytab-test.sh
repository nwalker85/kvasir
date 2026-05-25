#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
STUB_DIR="${TMPDIR}/bin"
mkdir -p "${STUB_DIR}"
trap 'rm -rf "${TMPDIR}"' EXIT

cat >"${TMPDIR}/kvasir.env" <<'ENV'
KVASIR_FREEIPA_HOST="hrafngud-ts-svc"
KVASIR_FREEIPA_CONTAINER="freeipa"
KVASIR_FREEIPA_DOMAIN="ravenhelm.dev"
KVASIR_FREEIPA_REALM="RAVENHELM.DEV"
KVASIR_DRY_RUN=0
KVASIR_LOG_LEVEL=error
ENV

# Stub ssh: capture the docker exec command, emit canned base64 keytab
cat >"${STUB_DIR}/ssh" <<'STUB'
#!/usr/bin/env bash
if [[ "$*" == *"ipa-getkeytab"*"host/odin.ravenhelm.dev"* ]]; then
  printf 'AAEACgADAAxLRVlUQUItQllURVMK'
  exit 0
fi
printf 'unexpected ssh args: %s\n' "$*" >&2
exit 64
STUB
chmod +x "${STUB_DIR}/ssh"

cat >"${STUB_DIR}/op" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "${STUB_DIR}/op"

export PATH="${STUB_DIR}:${PATH}"
export KVASIR_ENV_FILE="${TMPDIR}/kvasir.env"

source "${ROOT}/lib/common.sh"
source "${ROOT}/lib/op.sh"
source "${ROOT}/lib/freeipa.sh"

kvasir::load_env

OUTPUT="$(ipa::host_keytab "odin.ravenhelm.dev")"
if [[ "$OUTPUT" != "AAEACgADAAxLRVlUQUItQllURVMK" ]]; then
  printf 'FAIL: expected canned keytab, got: %s\n' "$OUTPUT" >&2
  exit 1
fi
printf 'PASS: ipa::host_keytab returns base64-wrapped keytab\n'
