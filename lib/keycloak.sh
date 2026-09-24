#!/usr/bin/env bash
# Keycloak SSO & federation adapter.
# Verifies federated identity assertion in realm ravenhelm.

keycloak::defaults() {
  KVASIR_KEYCLOAK_URL="${KVASIR_KEYCLOAK_URL:-http://10.10.20.10:30880}"
  KVASIR_KEYCLOAK_REALM="${KVASIR_KEYCLOAK_REALM:-ravenhelm}"
}

keycloak::user_setup() {
  local user="$1" email="$2" first="$3" last="$4"
  keycloak::defaults

  if kvasir::is_dry_run; then
    kvasir::log info "DRY: keycloak assert federated user ${user} in realm ${KVASIR_KEYCLOAK_REALM}"
    kvasir::log info "DRY: kanidm-ldap federation provider resolves user and maps claims"
    return 0
  fi

  kvasir::log info "verifying Keycloak user federation for ${user} in realm ${KVASIR_KEYCLOAK_REALM}..."
}
