#!/usr/bin/env bash
# FleetDM osquery endpoint management adapter.
# Provides enrollment secret discovery, agent configuration, and host enrollment.

fleetdm::defaults() {
  KVASIR_FLEET_URL="${KVASIR_FLEET_URL:-https://fleet.ravenmask.net:30882}"
  KVASIR_FLEET_HOST="${KVASIR_FLEET_HOST:-10.10.20.10:30882}"
}

fleetdm::enroll_secret() {
  if [[ -n "${KVASIR_FLEET_ENROLL_SECRET:-}" ]]; then
    printf '%s\n' "${KVASIR_FLEET_ENROLL_SECRET}"
    return 0
  fi
  # Discover enroll secret from OpenBao or fallback
  local secret
  secret=$(op::read_field "openbao-hrafngud-root-token" password 2>/dev/null || true)
  if [[ -n "$secret" ]]; then
    curl -fsS -H "X-Vault-Token: $secret" "http://10.10.20.10:8200/v1/secret/data/fleetdm/enroll_secret" 2>/dev/null \
      | jq -r '.data.data.enroll_secret // ""' 2>/dev/null || echo "eF2J4fq+DLpfQ7Q9t/ROEHgLiJb8sC3y"
  else
    echo "eF2J4fq+DLpfQ7Q9t/ROEHgLiJb8sC3y"
  fi
}

fleetdm::enroll_host() {
  local ssh_host="$1" fqdn="$2"
  fleetdm::defaults
  local secret
  secret="$(fleetdm::enroll_secret)"

  if kvasir::is_dry_run; then
    kvasir::log info "DRY: fleetdm enroll host=${fqdn} url=${KVASIR_FLEET_URL}"
    kvasir::log info "DRY: fleet-osquery package installed on ${ssh_host} with enroll secret"
    kvasir::log info "DRY: systemctl enable --now fleet-osquery on ${ssh_host}"
    return 0
  fi

  kvasir::log info "enrolling ${ssh_host} into FleetDM (${KVASIR_FLEET_URL})..."
  # Apply: write enroll secret and start osquery agent
  ssh "${ssh_host}" "echo '${secret}' | sudo tee /etc/fleet/enroll-secret >/dev/null && sudo systemctl restart fleet-osquery 2>/dev/null || true"
}
