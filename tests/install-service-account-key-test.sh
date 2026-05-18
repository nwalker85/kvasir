#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
STUB_DIR="${TMPDIR}/bin"
mkdir -p "${STUB_DIR}"
trap 'rm -rf "${TMPDIR}"' EXIT

cat >"${TMPDIR}/kvasir.env" <<'ENV'
KVASIR_FREEIPA_DOMAIN="ravenhelm.dev"
KVASIR_OP_VAULT="ravenmask"
KVASIR_DRY_RUN=1
KVASIR_LOG_LEVEL=error
ENV

cat >"${STUB_DIR}/op" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

case "$*" in
  *"--format json"*)
    jq -n --arg private_key "${KVASIR_TEST_PRIVATE_KEY}" \
      '{title:"FreeIPA Root Host vakr", fields:[
        {id:"password", label:"password", type:"CONCEALED", value:$private_key}
      ]}'
    ;;
  *)
    printf 'unexpected op args: %s\n' "$*" >&2
    exit 64
    ;;
esac
STUB
chmod +x "${STUB_DIR}/op"

cat >"${STUB_DIR}/ssh-keygen" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$1" == "-y" && "$2" == "-f" ]]; then
  printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest svc-vakr-root@vakr.ravenhelm.dev\n'
  exit 0
fi

printf 'unexpected ssh-keygen args: %s\n' "$*" >&2
exit 64
STUB
chmod +x "${STUB_DIR}/ssh-keygen"

cat >"${STUB_DIR}/ssh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

printf '%q ' "$@" >>"${KVASIR_TEST_SSH_LOG}"
printf '\n' >>"${KVASIR_TEST_SSH_LOG}"
cat >"${KVASIR_TEST_REMOTE_SCRIPT}"

case "$*" in
  *"svc-vakr-root@100.106.47.41"*bash\ -s*)
    exit 0
    ;;
  *)
    printf 'unexpected ssh args: %s\n' "$*" >&2
    exit 64
    ;;
esac
STUB
chmod +x "${STUB_DIR}/ssh"

OUT="${TMPDIR}/out"
ERR="${TMPDIR}/err"
SSH_LOG="${TMPDIR}/ssh.log"
REMOTE_SCRIPT="${TMPDIR}/remote.sh"
: >"${SSH_LOG}"

PATH="${STUB_DIR}:$PATH" \
  KVASIR_ENV_FILE="${TMPDIR}/kvasir.env" \
  KVASIR_TEST_SSH_LOG="${SSH_LOG}" \
  KVASIR_TEST_REMOTE_SCRIPT="${REMOTE_SCRIPT}" \
  KVASIR_TEST_PRIVATE_KEY="-----BEGIN OPENSSH PRIVATE KEY-----
stub-key
-----END OPENSSH PRIVATE KEY-----" \
  "${ROOT}/bin/kvasir" install-service-account-key vakr --ssh-host 100.106.47.41 --apply >"${OUT}" 2>"${ERR}"

grep -Fq 'svc-vakr-root@100.106.47.41' "${SSH_LOG}"
grep -Fq 'authorized_keys' "${REMOTE_SCRIPT}"
# shellcheck disable=SC2016
grep -Fq 'grep -Fxq "$pubkey"' "${REMOTE_SCRIPT}"

printf 'ok - install service account key\n'
