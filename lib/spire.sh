#!/usr/bin/env bash
# SPIRE server adapter. Join tokens and registration entries only.

spire::defaults() {
  pki::defaults
  KVASIR_SPIRE_AGENT_SPIFFE_ID="${KVASIR_SPIRE_AGENT_SPIFFE_ID:-spiffe://${KVASIR_SPIRE_TRUST_DOMAIN}/infra/spire-agent/hrafngud}"
  KVASIR_SPIRE_JOIN_TOKEN_TTL="${KVASIR_SPIRE_JOIN_TOKEN_TTL:-600}"
  KVASIR_SPIRE_JOIN_TOKEN_OP_PREFIX="${KVASIR_SPIRE_JOIN_TOKEN_OP_PREFIX:-SPIRE Join}"
}

spire::ssh_host() {
  spire::defaults
  printf '%s\n' "${KVASIR_SPIRE_HOST}"
}

# Run spire-server inside the container. Args are passed as argv (safe quoting).
spire::server() {
  local -a argv=(/opt/spire/bin/spire-server "$@")
  local remote_cmd="docker exec '${KVASIR_SPIRE_CONTAINER}'"
  local arg
  spire::defaults
  for arg in "${argv[@]}"; do
    remote_cmd+=" $(printf '%q' "$arg")"
  done
  ssh -o BatchMode=yes -o ConnectTimeout=8 "$(spire::ssh_host)" "$remote_cmd"
}

spire::preflight() {
  pki::defaults
  kvasir::log info "spire: host=${KVASIR_SPIRE_HOST} container=${KVASIR_SPIRE_CONTAINER} bind=${KVASIR_SPIRE_BIND} domain=${KVASIR_SPIRE_TRUST_DOMAIN}"
  if kvasir::is_dry_run; then
    kvasir::log info "DRY: spire-server healthcheck"
    return 0
  fi
  spire::server healthcheck >/dev/null \
    || kvasir::die "SPIRE server healthcheck failed on ${KVASIR_SPIRE_HOST}"
}

spire::spiffe_id() {
  pki::spiffe_id "$1"
}

spire::entry_show() {
  spire::server entry show -spiffeID "$1"
}

spire::entry_count() {
  local spiffe="$1" out
  out="$(spire::server entry show -spiffeID "$spiffe" 2>/dev/null || true)"
  if [[ "$out" =~ Found[[:space:]]+0[[:space:]]+entries ]]; then
    echo 0
  elif [[ "$out" =~ Found[[:space:]]+([0-9]+)[[:space:]]+entries ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    echo 0
  fi
}

spire::entry_exists() {
  [[ "$(spire::entry_count "$1")" -gt 0 ]]
}

spire::entry_create_plan() {
  local workload="$1"
  local selector="${2:-}"
  local spiffe parent
  spire::defaults
  [[ -z "$selector" ]] && selector="unix:user:${workload}"
  spiffe="$(spire::spiffe_id "$workload")"
  parent="${KVASIR_SPIRE_AGENT_SPIFFE_ID}"
  cat <<EOF
spire-entry:
  spiffe_id: ${spiffe}
  parent: ${parent}
  selector: ${selector}
  apply: spire-server entry create ...
  token: mint join token; store in 1Password; do not print
  agent: skipped unless --install-agent
EOF
}

spire::entry_create() {
  local workload="$1"
  local selector="${2:-}"
  local spiffe parent
  spire::defaults
  [[ -z "$selector" ]] && selector="unix:user:${workload}"
  spiffe="$(spire::spiffe_id "$workload")"
  parent="${KVASIR_SPIRE_AGENT_SPIFFE_ID}"

  if kvasir::is_dry_run; then
    spire::entry_create_plan "$workload" "$selector"
    kvasir::log info "DRY: spire-server entry create -spiffeID ${spiffe} -parentID ${parent} -selector ${selector}"
    return 0
  fi

  if spire::entry_exists "$spiffe"; then
    kvasir::log info "spire entry already exists: ${spiffe}"
    return 0
  fi

  spire::server entry create \
    -spiffeID "$spiffe" \
    -parentID "$parent" \
    -selector "$selector" \
    || kvasir::die "spire-server entry create failed for ${spiffe}"
  kvasir::log info "spire entry created: ${spiffe}"
}

spire::join_token_op_title() {
  local workload="$1"
  spire::defaults
  printf '%s %s\n' "${KVASIR_SPIRE_JOIN_TOKEN_OP_PREFIX}" "${workload#/}"
}

# Mint a join token and store in 1Password. Never prints the token.
spire::join_token_mint() {
  local workload="$1" ttl="${2:-${KVASIR_SPIRE_JOIN_TOKEN_TTL:-600}}"
  local spiffe out token title
  spire::defaults
  spiffe="$(spire::spiffe_id "$workload")"
  title="$(spire::join_token_op_title "$workload")"

  if kvasir::is_dry_run; then
    kvasir::log info "DRY: spire-server token generate -spiffeID ${spiffe} -ttl ${ttl}"
    kvasir::log info "DRY: op item create/update '${title}' concealed:join-token=***"
    return 0
  fi

  out="$(spire::server token generate -spiffeID "$spiffe" -ttl "$ttl")"
  token="$(printf '%s\n' "$out" | awk -F': ' '/^Token:/ {print $2; exit}')"
  [[ -n "$token" ]] || kvasir::die "could not parse SPIRE join token from server output"

  if op::item_exists "$title"; then
    op::set_field "$title" "join-token" "$token"
  else
    op::create_item "$title" "${KVASIR_OP_VAULT}" \
      "spiffe-id=${spiffe}" \
      "concealed:join-token=${token}" \
      "ttl-seconds=${ttl}"
  fi
  kvasir::log info "SPIRE join token stored in 1Password: ${title} (not printed)"
}

spire::entry_delete() {
  local workload="$1"
  local spiffe out entry_id
  spiffe="$(spire::spiffe_id "$workload")"

  if kvasir::is_dry_run; then
    kvasir::log info "DRY: spire-server entry delete for ${spiffe}"
    return 0
  fi

  if ! spire::entry_exists "$spiffe"; then
    kvasir::log info "spire entry not found: ${spiffe}"
    return 0
  fi

  out="$(spire::entry_show "$spiffe")"
  entry_id="$(printf '%s\n' "$out" | awk -F': ' '/^Entry ID/ {print $2; exit}')"
  [[ -n "$entry_id" ]] || kvasir::die "could not parse SPIRE entry id for ${spiffe}"

  spire::server entry delete -entryID "$entry_id" \
    || kvasir::die "spire-server entry delete failed for ${entry_id}"
  kvasir::log info "spire entry deleted: ${spiffe} (${entry_id})"
}

spire::join_token_cmd() {
  local workload="$1"
  local spiffe
  spire::defaults
  spiffe="$(spire::spiffe_id "$workload")"
  printf 'spire-server token generate -spiffeID %q -ttl %s\n' "$spiffe" "${KVASIR_SPIRE_JOIN_TOKEN_TTL:-600}"
}
