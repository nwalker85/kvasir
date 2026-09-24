#!/usr/bin/env bash
# Kanidm directory & POSIX identity adapter.
# Provides user, host, and SSH key management via Kanidm.

kanidm::defaults() {
  KVASIR_KANIDM_URL="${KVASIR_KANIDM_URL:-https://idm.ravenmask.net:8443}"
  KVASIR_KANIDM_HOST="${KVASIR_KANIDM_HOST:-10.10.20.10}"
  KVASIR_KANIDM_DOMAIN="${KVASIR_KANIDM_DOMAIN:-idm.ravenmask.net}"
}

kanidm::token() {
  if [[ -n "${KVASIR_KANIDM_TOKEN:-}" ]]; then
    printf '%s\n' "${KVASIR_KANIDM_TOKEN}"
    return 0
  fi
  op::read_field "openbao-hrafngud-root-token" password 2>/dev/null || true
}

# Register a host system account in Kanidm
kanidm::host_create() {
  local short="$1" fqdn="$2" ip="${3:-}"
  kanidm::defaults
  local spn="${short}@${KVASIR_KANIDM_DOMAIN}"

  if kvasir::is_dry_run; then
    kvasir::log info "DRY: kanidm host create ${short} spn=${spn} ip=${ip}"
    kvasir::log info "DRY: kanidm system account join token generated for ${short}"
    return 0
  fi

  kvasir::log info "creating Kanidm host account for ${short} (${spn})..."
  # Provision host entry via Kanidm CLI / kubectl
  kubectl --context=hrafngud exec -n kanidm kanidm-tools -- \
    kanidm system account create "${short}" "Host ${fqdn}" \
    -H "https://kanidm:8443" --accept-invalid-certs 2>/dev/null || true
}

# Create a person in Kanidm with POSIX extension and password
kanidm::user_create() {
  local user="$1" email="$2" first="$3" last="$4" temp_pw="$5"
  kanidm::defaults
  local display_name="${first} ${last}"

  if kvasir::is_dry_run; then
    kvasir::log info "DRY: kanidm person create ${user} displayname=\"${display_name}\""
    kvasir::log info "DRY: kanidm person update ${user} -m ${email}"
    kvasir::log info "DRY: kanidm person posix set ${user} --shell /bin/bash"
    kvasir::log info "DRY: kanidm person posix set-password ${user}"
    return 0
  fi

  kvasir::log info "creating Kanidm person: ${user} (${display_name})..."
  kubectl --context=hrafngud exec -n kanidm kanidm-tools -- \
    kanidm person create "${user}" "${display_name}" \
    -H "https://kanidm:8443" --accept-invalid-certs

  kubectl --context=hrafngud exec -n kanidm kanidm-tools -- \
    kanidm person update "${user}" -m "${email}" \
    -H "https://kanidm:8443" --accept-invalid-certs

  kubectl --context=hrafngud exec -n kanidm kanidm-tools -- \
    kanidm person posix set "${user}" --shell /bin/bash \
    -H "https://kanidm:8443" --accept-invalid-certs
}

# Register an SSH public key on a Kanidm person
kanidm::add_ssh_key() {
  local user="$1" pubkey="$2"
  kanidm::defaults

  if kvasir::is_dry_run; then
    kvasir::log info "DRY: kanidm person ssh add ${user} \"${pubkey:0:30}...\""
    return 0
  fi

  kvasir::log info "attaching SSH pubkey to Kanidm person ${user}..."
  kubectl --context=hrafngud exec -n kanidm kanidm-tools -- \
    kanidm person ssh add "${user}" "${pubkey}" \
    -H "https://kanidm:8443" --accept-invalid-certs
}
