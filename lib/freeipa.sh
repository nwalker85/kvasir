#!/usr/bin/env bash
# FreeIPA helpers. All ipa CLI calls run inside the freeipa container on
# the FreeIPA services host (default: hrafngud-ts-svc, fallback: hrafngud-svc)
# over SSH. Bypasses /ipa/json (S4U2Proxy bug).

KVASIR_FREEIPA_DOCKER_SUDO_PASSWORD_OP="${KVASIR_FREEIPA_DOCKER_SUDO_PASSWORD_OP:-}"
KVASIR_FREEIPA_HOST_FALLBACKS="${KVASIR_FREEIPA_HOST_FALLBACKS:-hrafngud-svc}"
_KVASIR_FREEIPA_DOCKER_SUDO_PW_CACHE=""

ipa::_resolve_docker_sudo_pw() {
  if [[ -z "${KVASIR_FREEIPA_DOCKER_SUDO_PASSWORD_OP}" ]]; then
    printf ''
    return 0
  fi
  if [[ -z "${_KVASIR_FREEIPA_DOCKER_SUDO_PW_CACHE}" ]]; then
    _KVASIR_FREEIPA_DOCKER_SUDO_PW_CACHE="$(op read "${KVASIR_FREEIPA_DOCKER_SUDO_PASSWORD_OP}" 2>/dev/null)" \
      || kvasir::die "could not resolve KVASIR_FREEIPA_DOCKER_SUDO_PASSWORD_OP=${KVASIR_FREEIPA_DOCKER_SUDO_PASSWORD_OP}"
  fi
  printf '%s' "${_KVASIR_FREEIPA_DOCKER_SUDO_PW_CACHE}"
}

ipa::docker_exec() {
  local cmd="$1" stdin="${2:-}" pw
  pw="$(ipa::_resolve_docker_sudo_pw)"
  local host rc host_list
  host_list="${KVASIR_FREEIPA_HOST}"
  [[ -n "${KVASIR_FREEIPA_HOST_FALLBACKS}" ]] && host_list+=" ${KVASIR_FREEIPA_HOST_FALLBACKS}"

  for host in ${host_list}; do
    if [[ -n "$pw" ]]; then
      if [[ -n "$stdin" ]]; then
        local remote_tmp
        remote_tmp="$(mktemp /tmp/kvasir.XXXXXX)"
        ssh -o BatchMode=yes -o ConnectTimeout=8 "${host}" "umask 077; cat > '${remote_tmp}'" <<<"$stdin"
        {
          printf '%s\n' "$pw"
        } | ssh -o BatchMode=yes -o ConnectTimeout=8 "${host}" "sudo -S -p '' bash -lc 'docker exec -i \"${KVASIR_FREEIPA_CONTAINER}\" bash -lc \"\$1\" < \"\$2\"; rc=\$?; rm -f \"\$2\"; exit \$rc' _ \"$cmd\" '${remote_tmp}'"
        rc=$?
      else
        {
          printf '%s\n' "$pw"
        } | ssh -o BatchMode=yes -o ConnectTimeout=8 "${host}" "sudo -S -p '' docker exec '${KVASIR_FREEIPA_CONTAINER}' bash -lc '${cmd}'"
        rc=$?
      fi
    else
      if [[ -n "$stdin" ]]; then
        ssh -o BatchMode=yes -o ConnectTimeout=8 "${host}" "docker exec -i '${KVASIR_FREEIPA_CONTAINER}' bash -lc '${cmd}'" <<<"$stdin"
      else
        ssh -o BatchMode=yes -o ConnectTimeout=8 "${host}" "docker exec '${KVASIR_FREEIPA_CONTAINER}' bash -lc '${cmd}'"
      fi
      rc=$?
    fi
    if (( rc == 0 )); then
      [[ "$host" != "${KVASIR_FREEIPA_HOST}" ]] && kvasir::log info "freeipa host fallback selected: ${host}"
      return 0
    fi
    kvasir::log warn "freeipa host ${host} unavailable for docker exec; trying next fallback"
  done

  return 1
}

ipa::directory_manager_password() {
  local field="${KVASIR_OP_FREEIPA_DM_PASSWORD_FIELD:-Directory Manager Password}"
  local pw
  pw="$(op item get "${KVASIR_OP_FREEIPA_SERVER_ITEM}" --vault "${KVASIR_OP_VAULT}" \
    --fields "$field" --reveal 2>/dev/null)" \
    || kvasir::die "could not read Directory Manager password (${field})"
  printf '%s' "$pw"
}

ipa::admin_password() {
  local field="${KVASIR_OP_FREEIPA_ADMIN_PASSWORD_FIELD:-password}"
  local pw
  pw="$(op item get "${KVASIR_OP_FREEIPA_SERVER_ITEM}" --vault "${KVASIR_OP_VAULT}" \
    --fields "$field" --reveal 2>/dev/null)" \
    || pw="$(op::read_field "${KVASIR_OP_FREEIPA_SERVER_ITEM}" password)"
  [[ -n "$pw" ]] || kvasir::die "could not read IPA admin Kerberos password (${field})"
  printf '%s' "$pw"
}

ipa::admin_kinit_in_container() {
  local pw principal="${KVASIR_FREEIPA_KINIT_PRINCIPAL:-admin}"
  pw="$(ipa::admin_password)"
  ipa::docker_exec "umask 077; kinit ${principal} >/dev/null" "$pw" \
    || kvasir::die "kinit ${principal} failed in freeipa container"
  kvasir::log debug "kinit ${principal} OK in ${KVASIR_FREEIPA_CONTAINER}"
}

ipa::admin_kinit_optional() {
  local pw principal="${KVASIR_FREEIPA_KINIT_PRINCIPAL:-admin}"
  pw="$(ipa::admin_password)"
  ipa::docker_exec "umask 077; kinit ${principal} >/dev/null" "$pw" && return 0
  return 1
}

# Run a single `ipa` subcommand in the container. Stdout returned to caller.
ipa::cmd() {
  local -a escaped=()
  local arg
  for arg in "$@"; do
    escaped+=( "$(printf '%q' "$arg")" )
  done
  ipa::docker_exec "ipa ${escaped[*]}"
}

# Submit a CSR generated on the subject. Kvasir never sees the private key.
# Args: <csr-file> <principal> <profile>
ipa::cert_request() {
  local csr="$1" principal="$2" profile="$3"
  local csr_pem principal_q profile_q
  [[ -f "$csr" ]] || kvasir::die "CSR not found: ${csr}"
  if kvasir::is_dry_run; then
    kvasir::log info "DRY: ipa cert-request --principal ${principal} --profile ${profile} < ${csr}"
    return 0
  fi
  csr_pem="$(cat "$csr")"
  principal_q="$(printf '%q' "$principal")"
  profile_q="$(printf '%q' "$profile")"
  ipa::docker_exec \
    "cat >/tmp/kvasir.csr && ipa cert-request /tmp/kvasir.csr --principal ${principal_q} --profile ${profile_q}; rc=\$?; rm -f /tmp/kvasir.csr; exit \$rc" \
    "$csr_pem"
}

ipa::cert_find() {
  ipa::cmd cert-find --principal "$1"
}

ipa::cert_revoke() {
  ipa::cmd cert-revoke "$1"
}

ipa::ca_show() {
  ipa::cmd ca-show
}

ipa::ldap_base_dn() {
  local domain="${KVASIR_FREEIPA_DOMAIN:-ravenhelm.dev}"
  local part joined=""
  local -a parts=()
  IFS=. read -r -a parts <<<"${domain}"
  for part in "${parts[@]}"; do
    if [[ -n "$joined" ]]; then joined+=","
    fi
    joined+="dc=${part}"
  done
  printf '%s' "$joined"
}

# Read-only Dogtag reachability via LDAP (Directory Manager). No Kerberos ticket.
ipa::docker_bash_script() {
  local script="$1"
  local host rc host_list
  host_list="${KVASIR_FREEIPA_HOST}"
  [[ -n "${KVASIR_FREEIPA_HOST_FALLBACKS}" ]] && host_list+=" ${KVASIR_FREEIPA_HOST_FALLBACKS}"
  for host in ${host_list}; do
    if printf '%s' "$script" | ssh -o BatchMode=yes -o ConnectTimeout=8 "${host}"       "docker exec -i '${KVASIR_FREEIPA_CONTAINER}' bash -s"; then
      [[ "$host" != "${KVASIR_FREEIPA_HOST}" ]] && kvasir::log info "freeipa host fallback selected: ${host}"
      return 0
    fi
    kvasir::log warn "freeipa host ${host} unavailable for docker bash; trying next fallback"
  done
  return 1
}

ipa::ldap_ca_probe() {
  local pw ldap_base pw_b64 script
  pw="$(ipa::directory_manager_password)"
  ldap_base="$(ipa::ldap_base_dn)"
  if kvasir::is_dry_run; then
    kvasir::log info "DRY: ldapsearch Dogtag CA cn=ipa,cn=cas,cn=ca,${ldap_base}"
    return 0
  fi
  pw_b64="$(printf '%s' "$pw" | base64 | tr -d '
')"
  script="$(cat <<EOS
set -euo pipefail
PW="\$(printf '%s' '${pw_b64}' | base64 -d)"
f="\$(mktemp)"
printf '%s' "\$PW" >"\$f"
ldapsearch -x -H ldap://localhost -b "cn=ipa,cn=cas,cn=ca,${ldap_base}" \
  -D "cn=Directory Manager" -y "\$f" dn 2>/dev/null | grep -q '^dn:'
rm -f "\$f"
EOS
)"
  ipa::docker_bash_script "$script"     || kvasir::die "Dogtag CA LDAP probe failed in ${KVASIR_FREEIPA_CONTAINER}"
  kvasir::log info "dogtag CA LDAP probe ok (cn=ipa,cn=cas,cn=ca,${ldap_base})"
}

ipa::dogtag_preflight() {
  kvasir::log info "dogtag: realm=${KVASIR_FREEIPA_REALM} container=${KVASIR_FREEIPA_CONTAINER}"
  if kvasir::is_dry_run; then
    kvasir::log info "DRY: ldap CA probe + optional ipa ca-show"
    return 0
  fi
  ipa::ldap_ca_probe
  if ipa::admin_kinit_optional; then
    ipa::ca_show >/dev/null && kvasir::log info "dogtag ipa ca-show ok"
  else
    kvasir::log warn "ipa ca-show skipped — admin Kerberos kinit failed; LDAP CA probe passed"
  fi
}

# host-add (always fresh) with a hex OTP. Echoes the OTP on stdout.
# Args: <fqdn>
#
# If a host record already exists with a keytab attached, `ipa host-mod
# --password=<otp>` fails with "Password cannot be set on enrolled host".
# Cleanest path: delete the existing host record (invalidates the
# server-side keytab), then re-add with the new OTP. The client side must
# then run `ipa-client-install --uninstall && --install` to get a fresh
# keytab — enroll-host handles that.
ipa::host_register() {
  local fqdn="$1"
  local otp
  otp="$(openssl rand -hex 16)"
  if kvasir::is_dry_run; then
    kvasir::log info "DRY: ipa host-add ${fqdn} --password=<otp> --force (or host-del+host-add if exists)"
    echo "$otp"
    return 0
  fi
  if ipa::cmd host-show "$fqdn" >/dev/null 2>&1; then
    ipa::cmd host-del "$fqdn" >/dev/null
    kvasir::log info "freeipa host-del ${fqdn} (was already enrolled — keytab invalidated)"
  fi
  ipa::cmd host-add "$fqdn" --password="$otp" --force >/dev/null
  kvasir::log info "freeipa host-add ${fqdn}"
  echo "$otp"
}

# Push an SSH pubkey to a user via additive attr (does NOT overwrite existing keys).
# Args: <username> <pubkey-line>
ipa::user_addsshpubkey() {
  local user="$1" pubkey="$2"
  # ipa user-mod --addattr only available via the cli; quote pubkey carefully.
  if kvasir::is_dry_run; then
    kvasir::log info "DRY: ipa user-mod ${user} --addattr=ipasshpubkey=<key>"
    return 0
  fi
  local out rc
  out=$(ipa::docker_exec "ipa user-mod '${user}' --addattr=\"ipasshpubkey=${pubkey}\"" 2>&1) && rc=0 || rc=$?
  if (( rc == 0 )); then
    kvasir::log info "freeipa: SSH key added to user ${user}"
  elif grep -qiE 'no modifications to be performed|already a member|attribute.*value' <<<"$out"; then
    kvasir::log warn "freeipa: SSH key already attached to ${user} — no-op"
  else
    kvasir::log error "ipa user-mod --addattr failed for ${user}: $out"
    return 1
  fi
}

# Add a certificate to a user entry.
# Args: <username> <certificate-b64-or-pem>
ipa::user_add_cert() {
  local user="$1" cert="$2"
  if kvasir::is_dry_run; then
    kvasir::log info "DRY: ipa user-add-cert ${user} --certificate=<cert>"
    return 0
  fi
  local out rc
  out=$(ipa::docker_exec "ipa user-add-cert '${user}' --certificate='${cert}'" 2>&1) && rc=0 || rc=$?
  if (( rc == 0 )); then
    kvasir::log info "freeipa: certificate added to user ${user}"
  elif grep -qiE 'already|duplicate|no modifications' <<<"$out"; then
    kvasir::log warn "freeipa: certificate already attached to ${user} — no-op"
  else
    kvasir::log error "ipa user-add-cert failed for ${user}: $out"
    return 1
  fi
}

# Create or refresh the FreeIPA user record for a host-scoped root-capable
# service account. Credential material is handled separately so callers can
# update the account without forcing a new keypair/certificate every time.
# Args: <uid> <first> <last> <email> <shell> <home>
ipa::service_account_upsert_root_user() {
  local uid="$1" first="$2" last="$3" email="$4" shell="$5" home="$6"
  local out rc

  if ! ipa::cmd user-show "$uid" >/dev/null 2>&1; then
    if kvasir::is_dry_run; then
      kvasir::log info "DRY: ipa user-add ${uid} --first=${first} --last=${last} --email=${email} --shell=${shell} --homedir=${home}"
    else
      ipa::cmd user-add "$uid" \
        --first="${first}" \
        --last="${last}" \
        --email="${email}" \
        --shell="${shell}" \
        --homedir="${home}" >/dev/null
      kvasir::log info "freeipa service account created: ${uid}"
    fi
  else
    if kvasir::is_dry_run; then
      kvasir::log info "DRY: ipa user-mod ${uid} --shell=${shell} --homedir=${home} --email=${email}"
    else
      out=$(ipa::cmd user-mod "$uid" \
        --shell="${shell}" \
        --homedir="${home}" \
        --email="${email}" 2>&1) && rc=0 || rc=$?
      if (( rc == 0 )); then
        kvasir::log info "freeipa service account exists: ${uid} — refreshed shell/home/mail"
      elif grep -qiE 'no modifications to be performed|no changes were made' <<<"$out"; then
        kvasir::log info "freeipa service account exists: ${uid} — already in sync"
      else
        kvasir::log error "freeipa user-mod failed for ${uid}: ${out}"
        return "$rc"
      fi
    fi
  fi
}

# Attach the generated credential artifacts to an existing service account.
# Args: <uid> <ssh-pubkey> <certificate-b64>
ipa::service_account_attach_root_credentials() {
  local uid="$1" ssh_pubkey="$2" cert="$3"

  ipa::user_addsshpubkey "$uid" "$ssh_pubkey"
  ipa::user_add_cert "$uid" "$cert"
}

# Create or refresh a host-scoped root-capable service account.
# Args: <uid> <first> <last> <email> <shell> <home> <ssh-pubkey> <certificate-b64>
ipa::service_account_bootstrap_root() {
  local uid="$1" first="$2" last="$3" email="$4" shell="$5" home="$6"
  local ssh_pubkey="$7" cert="$8"

  ipa::service_account_upsert_root_user "$uid" "$first" "$last" "$email" "$shell" "$home"
  ipa::service_account_attach_root_credentials "$uid" "$ssh_pubkey" "$cert"
}

ipa::cmd_idempotent() {
  local out rc
  out=$(ipa::cmd "$@" 2>&1) && return 0 || rc=$?
  if grep -qiE 'already|duplicate|no modifications|no changes were made' <<<"$out"; then
    return 0
  fi
  kvasir::log error "freeipa command failed: ipa $*"
  kvasir::log error "$out"
  return "$rc"
}

# Create or refresh a host-scoped sudo rule that grants passwordless root.
# Args: <rule-name> <uid> <host-fqdn>
ipa::service_account_bootstrap_root_sudo() {
  local rule="$1" uid="$2" host="$3"

  if ! ipa::cmd sudorule-show "$rule" >/dev/null 2>&1; then
    if kvasir::is_dry_run; then
      kvasir::log info "DRY: ipa sudorule-add ${rule} --desc='Root access for ${uid} on ${host}' --runasusercat=all --runasgroupcat=all --cmdcat=all"
    else
      ipa::cmd sudorule-add "$rule" \
        --desc="Root access for ${uid} on ${host}" \
        --runasusercat=all \
        --runasgroupcat=all \
        --cmdcat=all >/dev/null
      kvasir::log info "freeipa sudo rule created: ${rule}"
    fi
  else
    kvasir::log info "freeipa sudo rule exists: ${rule}"
  fi

  if kvasir::is_dry_run; then
    kvasir::log info "DRY: ipa sudorule-add-user ${rule} --users=${uid}"
    kvasir::log info "DRY: ipa sudorule-add-host ${rule} --hosts=${host}"
    kvasir::log info "DRY: ipa sudorule-add-option ${rule} --sudooption='!authenticate'"
    return 0
  fi

  ipa::cmd_idempotent sudorule-add-user "$rule" --users="$uid" >/dev/null
  ipa::cmd_idempotent sudorule-add-host "$rule" --hosts="$host" >/dev/null
  ipa::cmd_idempotent sudorule-add-option "$rule" --sudooption='!authenticate' >/dev/null
}

# Ensure the host-scoped root service account exists and is wired for the
# given host. This updates the user record and sudo rule on every run, but
# only creates a fresh credential bundle when the 1Password item does not
# already exist.
# Args: <short> <fqdn> <lan-ip>
ipa::service_account_ensure_root() {
  local short="$1" fqdn="$2" lan_ip="${3:-}"
  local uid="svc-${short}-root"
  local first="Kvasir"
  local last="Root"
  local email="${uid}@${KVASIR_FREEIPA_DOMAIN}"
  local home="/home/${uid}"
  local shell="/bin/bash"
  local rule="kvasir-root-${short}"
  local item_title="FreeIPA Root Host ${short}"
  local item_exists=1

  if kvasir::is_dry_run; then
    kvasir::log info "DRY: would upsert ${uid}, ensure sudo rule ${rule}, and create/update 1Password item ${item_title}"
    return 0
  fi

  ipa::admin_kinit_in_container

  ipa::service_account_upsert_root_user \
    "${uid}" \
    "${first}" \
    "${last}" \
    "${email}" \
    "${shell}" \
    "${home}"

  ipa::service_account_bootstrap_root_sudo \
    "${rule}" \
    "${uid}" \
    "${fqdn}"

  if ! op::item_exists "${item_title}" "${KVASIR_OP_VAULT}"; then
    item_exists=0
  fi

  if (( item_exists == 1 )); then
    kvasir::log info "freeipa root service account already has a 1Password item: ${item_title} — user + sudo rule refreshed only"
    return 0
  fi

  kvasir::log info "[root-account] issuing initial credential bundle..."
  local artifact_dir root_key root_cert_key root_cert_pem root_cert_b64 root_ssh_pubkey root_private_key root_notes
  local -a item_fields
  artifact_dir="$(mktemp -d)"
  root_key="${artifact_dir}/${uid}"
  root_cert_key="${artifact_dir}/${uid}-cert.key"
  root_cert_pem="${artifact_dir}/${uid}.crt"

  ssh-keygen -q -t ed25519 -f "${root_key}" -N '' -C "${uid}@${fqdn}"
  openssl req -new -x509 \
    -newkey rsa:2048 \
    -nodes \
    -keyout "${root_cert_key}" \
    -out "${root_cert_pem}" \
    -days 3650 \
    -subj "/CN=${uid}/O=Ravenhelm/OU=Kvasir Root Access" \
    -addext "basicConstraints=critical,CA:FALSE" \
    -addext "keyUsage=critical,digitalSignature,keyEncipherment" \
    -addext "extendedKeyUsage=clientAuth"

  root_cert_b64="$(openssl x509 -in "${root_cert_pem}" -outform der | base64 | tr -d '\n')"
  root_ssh_pubkey="$(cat "${root_key}.pub")"
  root_private_key="$(cat "${root_key}")"
  root_notes="$(cat <<EOF
SSH public key:
${root_ssh_pubkey}

Certificate:
$(cat "${root_cert_pem}")

Root sudo rule: ${rule}
Host: ${fqdn}
LAN IP: ${lan_ip:-unknown}
EOF
)"

  ipa::service_account_attach_root_credentials \
    "${uid}" \
    "${root_ssh_pubkey}" \
    "${root_cert_b64}"

  item_fields=(
    "username=${uid}"
    "concealed:password=${root_private_key}"
    "url=https://${KVASIR_FREEIPA_FQDN}"
    "fqdn=${fqdn}"
    "service-account=${uid}"
    "certificate-fingerprint=$(openssl x509 -in "${root_cert_pem}" -noout -fingerprint -sha256 | sed 's/^.*=//')"
    "notesPlain=${root_notes}"
  )
  [[ -n "${lan_ip}" ]] && item_fields+=( "lan-ip=${lan_ip}" )

  op::create_item "${item_title}" "${KVASIR_OP_VAULT}" \
    "${item_fields[@]}"

  rm -rf "${artifact_dir}"
}

# Create a FreeIPA user. Args: <user> <first> <last> <email> <random-pw>
ipa::user_add() {
  local user="$1" first="$2" last="$3" email="$4" pw="$5"
  if ipa::cmd user-show "$user" >/dev/null 2>&1; then
    kvasir::log warn "freeipa user ${user} already exists — skipping create"
    return 0
  fi
  if kvasir::is_dry_run; then
    kvasir::log info "DRY: ipa user-add ${user} --first=${first} --last=${last} --email=${email}"
    return 0
  fi
  # shellcheck disable=SC2029
  ssh "${KVASIR_FREEIPA_HOST}" \
    "docker exec -i '${KVASIR_FREEIPA_CONTAINER}' ipa user-add '${user}' \
        --first='${first}' --last='${last}' --email='${email}' \
        --password" <<<"$pw" >/dev/null \
    || kvasir::die "ipa user-add ${user} failed"
  kvasir::log info "freeipa user-add ${user}"
}

# Fetch the CA cert PEM (cached file inside container) to stdout.
ipa::ca_cert() {
  ipa::docker_exec "cat /etc/ipa/ca.crt"
}

# Mint a fresh host keytab for $FQDN inside the freeipa container and emit
# it as base64 on stdout. Caller must have run ipa::admin_kinit_in_container
# first (so ipa-getkeytab can authenticate). Each call rotates the host's
# kvno — matches Linux enroll-host's re-run-as-rotation semantics.
# Args: <fqdn>
ipa::host_keytab() {
  local fqdn="$1"
  if kvasir::is_dry_run; then
    kvasir::log info "DRY: ipa-getkeytab -p host/${fqdn} (would rotate kvno)"
    printf ''
    return 0
  fi
  # Cleanup runs regardless of base64's exit; real exit propagated via $rc.
  local cmd
  cmd="ipa-getkeytab -p host/${fqdn} -k /tmp/${fqdn}.keytab >/dev/null"
  cmd+=" && base64 < /tmp/${fqdn}.keytab; rc=\$?; rm -f /tmp/${fqdn}.keytab; exit \$rc"
  ipa::docker_exec "$cmd"
}
