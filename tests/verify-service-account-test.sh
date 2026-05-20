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

if [[ "${KVASIR_TEST_OP_MODE:-ok}" == "missing" ]]; then
  exit 1
fi

case "$*" in
  *"--format json"*)
    jq -n \
      --arg private_key "${KVASIR_TEST_PRIVATE_KEY:-test-private-key}" \
      '{title:"FreeIPA Root Host vakr", fields:[
        {id:"username", label:"username", type:"STRING", value:"svc-vakr-root"},
        {id:"password", label:"password", type:"CONCEALED", value:($private_key + "[password]")}
      ]}'
    ;;
  *"--fields password"*)
    printf '"%s"\n' "${KVASIR_TEST_PRIVATE_KEY:-test-private-key}"
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

args=("$@")
nonopts=()
identity_file=""
i=0
while (( i < ${#args[@]} )); do
  arg="${args[$i]}"
  case "$arg" in
    -i)
      (( i++ ))
      identity_file="${args[$i]}"
      ;;
    -o|-F|-J|-l|-p|-S|-b|-c|-D|-E|-e|-I|-L|-m|-O|-Q|-R|-W|-w)
      (( i++ ))
      ;;
    -*)
      ;;
    *)
      nonopts+=("$arg")
      ;;
  esac
  (( i++ ))
done

if (( ${#nonopts[@]} == 0 )); then
  printf 'missing ssh host\n' >&2
  exit 64
fi

host="${nonopts[0]}"
cmd=""
if (( ${#nonopts[@]} > 1 )); then
  cmd="${nonopts[*]:1}"
fi

mode="${KVASIR_TEST_SSH_MODE:-ok}"

if [[ "$host" == svc-vakr-root@* ]]; then
  [[ -n "$identity_file" ]] || { printf 'missing identity file\n' >&2; exit 65; }
  [[ -f "$identity_file" ]] || { printf 'identity file not found\n' >&2; exit 66; }
  [[ "$(cat "$identity_file")" == "${KVASIR_TEST_PRIVATE_KEY:-test-private-key}" ]] \
    || { printf 'identity file content mismatch\n' >&2; exit 67; }
fi

case "$cmd" in
  true)
    [[ "$mode" == "unreachable" ]] && exit 255
    exit 0
    ;;
  "getent passwd svc-vakr-root")
    [[ "$mode" == "getent_fail" ]] && exit 2
    printf 'svc-vakr-root:*:12101:12101:Kvasir Root:/home/svc-vakr-root:/bin/bash\n'
    ;;
  "sss_ssh_authorizedkeys svc-vakr-root")
    [[ "$mode" == "no_keys" ]] && exit 0
    printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest svc-vakr-root@vakr.ravenhelm.dev\n'
    ;;
  *authorized_keys*)
    [[ "$mode" == "auth_keys_missing" ]] && exit 1
    exit 0
    ;;
  id)
    [[ "$mode" == "login_fail" ]] && exit 255
    printf 'uid=12101(svc-vakr-root) gid=12101(svc-vakr-root) groups=12101(svc-vakr-root)\n'
    ;;
  "sudo -n true")
    [[ "$mode" == "sudo_fail" ]] && exit 1
    exit 0
    ;;
  *)
    printf 'unexpected ssh command for %s: %s\n' "$host" "$cmd" >&2
    exit 68
    ;;
esac
STUB
chmod +x "${STUB_DIR}/ssh"

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local file="$1" needle="$2"
  grep -Fq "$needle" "$file" || {
    printf 'expected to find: %s\n' "$needle" >&2
    printf '%s\n' "--- ${file} ---" >&2
    cat "$file" >&2
    fail "missing expected output"
  }
}

run_verify() {
  local mode="${1:-ok}"
  shift || true
  OUT="${TMPDIR}/out"
  ERR="${TMPDIR}/err"
  SSH_LOG="${TMPDIR}/ssh.log"
  : >"${SSH_LOG}"
  set +e
  PATH="${STUB_DIR}:$PATH" \
    KVASIR_ENV_FILE="${TMPDIR}/kvasir.env" \
    KVASIR_TEST_SSH_MODE="${mode}" \
    KVASIR_TEST_SSH_LOG="${SSH_LOG}" \
    KVASIR_TEST_PRIVATE_KEY="-----BEGIN OPENSSH PRIVATE KEY-----
stub-key
-----END OPENSSH PRIVATE KEY-----" \
    "${ROOT}/bin/kvasir" verify-service-account vakr "$@" >"${OUT}" 2>"${ERR}"
  STATUS=$?
  set -e
}

test_help_lists_verify_command() {
  local help_out="${TMPDIR}/help.out"
  PATH="${STUB_DIR}:$PATH" "${ROOT}/bin/kvasir" help >"${help_out}"
  assert_contains "${help_out}" "verify-service-account <target>"
}

test_success_table_and_noninteractive_ssh() {
  run_verify ok
  [[ "${STATUS}" -eq 0 ]] || fail "expected success, got ${STATUS}"
  assert_contains "${OUT}" "Host: vakr.ravenhelm.dev"
  assert_contains "${OUT}" "Service account: svc-vakr-root"
  assert_contains "${OUT}" "1Password item exists"
  assert_contains "${OUT}" "PASS    FreeIPA Root Host vakr"
  assert_contains "${OUT}" "SSSD authorized keys resolves"
  assert_contains "${OUT}" "PASS    1 key"
  assert_contains "${OUT}" "Host authorized_keys contains key"
  assert_contains "${OUT}" "PASS    ~svc-vakr-root/.ssh/authorized_keys"
  assert_contains "${OUT}" "Passwordless sudo"
  assert_contains "${OUT}" "PASS    sudo -n true"
  assert_contains "${SSH_LOG}" "BatchMode=yes"
  assert_contains "${SSH_LOG}" "PasswordAuthentication=no"
  assert_contains "${SSH_LOG}" "svc-vakr-root@vakr"
  assert_contains "${SSH_LOG}" "sudo\\ -n\\ true"
}

test_route_override_separates_identity_from_ssh_host() {
  run_verify ok --ssh-host 100.106.47.41
  [[ "${STATUS}" -eq 0 ]] || fail "expected success, got ${STATUS}"
  assert_contains "${OUT}" "Host: vakr.ravenhelm.dev"
  assert_contains "${OUT}" "Target SSH reachable"
  assert_contains "${OUT}" "PASS    ssh svc-vakr-root@100.106.47.41 true"
  assert_contains "${SSH_LOG}" "svc-vakr-root@100.106.47.41 true"
  assert_contains "${SSH_LOG}" "svc-vakr-root@100.106.47.41 id"
}

test_missing_authorized_keys_prints_action() {
  run_verify no_keys
  [[ "${STATUS}" -ne 0 ]] || fail "expected non-zero status for missing keys"
  assert_contains "${OUT}" "SSSD authorized keys resolves      FAIL    0 keys"
  assert_contains "${OUT}" "Action: rerun kvasir service-account vakr --apply, then verify sshd uses sss_ssh_authorizedkeys"
}

test_sudo_failure_prints_action() {
  run_verify sudo_fail
  [[ "${STATUS}" -ne 0 ]] || fail "expected non-zero status for sudo failure"
  assert_contains "${OUT}" "Passwordless sudo                  FAIL"
  assert_contains "${OUT}" "Action: rerun kvasir service-account vakr --apply, then refresh the target SSSD sudo cache"
}

test_missing_host_authorized_keys_prints_action() {
  run_verify auth_keys_missing
  [[ "${STATUS}" -ne 0 ]] || fail "expected non-zero status for missing host authorized_keys"
  assert_contains "${OUT}" "Host authorized_keys contains key  FAIL"
  assert_contains "${OUT}" "Action: run kvasir install-service-account-key vakr --ssh-host vakr --apply"
}

test_help_lists_verify_command
test_success_table_and_noninteractive_ssh
test_route_override_separates_identity_from_ssh_host
test_missing_authorized_keys_prints_action
test_sudo_failure_prints_action
test_missing_host_authorized_keys_prints_action

printf 'ok - verify-service-account tests\n'
