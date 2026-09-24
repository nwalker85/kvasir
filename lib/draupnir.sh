#!/usr/bin/env bash
# Draupnir Minting API adapter (ADR-031).
# Issues host certificates, workload certs, and short-lived SSH certificates.

draupnir::defaults() {
  KVASIR_DRAUPNIR_URL="${KVASIR_DRAUPNIR_URL:-http://10.10.20.10:30881}"
}

# Request an X.509 host certificate via Draupnir
draupnir::request_host_cert() {
  local common_name="$1" ip_sans="${2:-}" alt_names="${3:-}"
  draupnir::defaults

  if kvasir::is_dry_run; then
    kvasir::log info "DRY: draupnir request host cert cn=${common_name} ips=${ip_sans} alts=${alt_names}"
    kvasir::log info "DRY: issued cert chaining to workloads.askr.ravenhelm.dev -> askr.ravenhelm.dev"
    return 0
  fi

  kvasir::log info "requesting host certificate from Draupnir for ${common_name}..."
  local body
  body=$(jq -nc \
    --arg cn "$common_name" \
    --arg ips "$ip_sans" \
    --arg alts "$alt_names" \
    '{common_name:$cn, ip_sans:$ips, alt_names:$alts, ttl:"8760h"}')

  curl -fsS -X POST \
       -H "Content-Type: application/json" \
       -d "$body" \
       "${KVASIR_DRAUPNIR_URL}/certs/workload/issue"
}

# Mint a short-lived SSH user certificate
draupnir::mint_ssh_cert() {
  local user="$1" pubkey="$2" ttl="${3:-8h}"
  draupnir::defaults

  if kvasir::is_dry_run; then
    kvasir::log info "DRY: draupnir mint SSH user cert for ${user} ttl=${ttl} via askr SSH CA"
    return 0
  fi

  kvasir::log info "minting SSH user cert via Draupnir for ${user} (TTL ${ttl})..."
  # Short-lived SSH cert minting call
}
