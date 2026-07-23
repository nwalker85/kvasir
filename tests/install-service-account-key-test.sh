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
  "read op://ravenmask/orange-pi/password")
    printf '%s\n' 'test-sudo-password'
    ;;
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

case "$*" in
  *"nwalker@100.106.47.41"*"umask 077; cat >"*)
    cat >"${KVASIR_TEST_REMOTE_SCRIPT}"
    exit 0
    ;;
  *"nwalker@100.106.47.41"*"sudo -S -p"*)
    cat >"${KVASIR_TEST_SUDO_STDIN}"
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
SUDO_STDIN="${TMPDIR}/sudo.stdin"
: >"${SSH_LOG}"

PATH="${STUB_DIR}:$PATH" \
  KVASIR_ENV_FILE="${TMPDIR}/kvasir.env" \
  KVASIR_TEST_SSH_LOG="${SSH_LOG}" \
  KVASIR_TEST_REMOTE_SCRIPT="${REMOTE_SCRIPT}" \
  KVASIR_TEST_SUDO_STDIN="${SUDO_STDIN}" \
  KVASIR_TEST_PRIVATE_KEY="-----BEGIN OPENSSH PRIVATE KEY-----
stub-key
-----END OPENSSH PRIVATE KEY-----" \
  KVASIR_SUDO_PASSWORD_OP="op://ravenmask/orange-pi/password" \
  "${ROOT}/bin/kvasir" install-service-account-key vakr --ssh-host 100.106.47.41 --bootstrap-user nwalker --apply >"${OUT}" 2>"${ERR}"

grep -Fq 'nwalker@100.106.47.41' "${SSH_LOG}"
grep -Fq 'authorized_keys' "${REMOTE_SCRIPT}"
if grep -Fq 'sudo -n' "${REMOTE_SCRIPT}"; then
  printf 'bootstrap script should already run under sudo\n' >&2
  exit 1
fi
grep -Fq 'sudo\ -S\ -p' "${SSH_LOG}"
grep -Fxq 'test-sudo-password' "${SUDO_STDIN}"

printf 'ok - install service account key\n'
