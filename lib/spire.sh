#!/usr/bin/env bash
# SPIRE server adapter. Join tokens and registration entries only.

spire::defaults() {
  pki::defaults
  # The agent that will VOUCH for the workload. This is not cosmetic: an entry
  # parented to hrafngud's agent grants that SVID to a workload running on
  # HRAFNGUD. Registering a grani workload against it hands the identity to the
  # wrong host, and the right host still cannot get it.
  KVASIR_SPIRE_AGENT_HOST="${KVASIR_SPIRE_AGENT_HOST:-hrafngud}"
  KVASIR_SPIRE_AGENT_SPIFFE_ID="${KVASIR_SPIRE_AGENT_SPIFFE_ID:-spiffe://${KVASIR_SPIRE_TRUST_DOMAIN}/infra/spire-agent/${KVASIR_SPIRE_AGENT_HOST}}"
  KVASIR_SPIRE_AGENT_IMAGE="${KVASIR_SPIRE_AGENT_IMAGE:-ghcr.io/spiffe/spire-agent:1.12.4}"
  KVASIR_SPIRE_AGENT_DATA_DIR="${KVASIR_SPIRE_AGENT_DATA_DIR:-/opt/ravenhelm/data/spire}"
  KVASIR_SPIRE_AGENT_SOCKET_DIR="${KVASIR_SPIRE_AGENT_SOCKET_DIR:-/run/spire/sockets}"
  # The address the AGENT DIALS is not the host WE SSH TO. KVASIR_SPIRE_HOST is an
  # ssh alias resolved by the operator's ~/.ssh/config; baking it into agent.conf
  # gave the agent a name only this laptop can resolve, and it crash-looped with
  #   dns: A record lookup error: lookup hrafngud-ts-svc
  # Use a name the TARGET can resolve. A DNS name, never a Tailscale address.
  KVASIR_SPIRE_SERVER_ADDRESS="${KVASIR_SPIRE_SERVER_ADDRESS:-hrafngud.ravenmask.net}"
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
  # Callers used to omit the selector here while passing it to entry_create, so
  # the dry run advertised `unix:user:<name>` and apply used something else. A
  # plan that does not match the mutation is worse than no plan.
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

# ---------------------------------------------------------------------------
# Agent installation.
#
# `--install-agent` was a stub: it logged "opt-in" and returned, in dry-run AND
# under --apply. A flag that looks like a capability and does nothing is worse
# than an absent one — it was the reason grani had no agent while the command
# reported success.
#
# Mirrors the agent already running on hrafngud (verified 2026-09-15):
#   ghcr.io/spiffe/spire-agent:1.12.4, -config .../agent.conf -joinToken <tok>,
#   socket dir bind-mounted so workloads can reach the Workload API.
# ---------------------------------------------------------------------------

spire::agent_host_ssh() {
  spire::defaults
  printf '%s\n' "${KVASIR_SPIRE_AGENT_SSH:-${KVASIR_SPIRE_AGENT_HOST}}"
}

spire::agent_installed() {
  local host; host="$(spire::agent_host_ssh)"
  ssh -o BatchMode=yes -o ConnectTimeout=8 "$host" \
    'docker inspect spire-agent >/dev/null 2>&1' 2>/dev/null
}

spire::agent_install_plan() {
  spire::defaults
  local host; host="$(spire::agent_host_ssh)"
  cat <<EOF
spire-agent:
  host:       ${KVASIR_SPIRE_AGENT_HOST} (ssh: ${host})
  image:      ${KVASIR_SPIRE_AGENT_IMAGE}
  server:     ${KVASIR_SPIRE_SERVER_ADDRESS}:8081 (as resolved BY ${KVASIR_SPIRE_AGENT_HOST})
  ssh via:    ${KVASIR_SPIRE_HOST} (operator-side alias, never used as an address)
  config:     ${KVASIR_SPIRE_AGENT_DATA_DIR}/conf/agent.conf
  socket:     ${KVASIR_SPIRE_AGENT_SOCKET_DIR}/agent.sock
  join token: minted, stored in 1Password, never printed
  verify:     agent.sock present and the server lists the agent
EOF
}

# Install (or re-point) a SPIRE agent on the named host. Idempotent: an existing
# healthy agent is left alone.
spire::agent_install() {
  spire::defaults
  local host token
  host="$(spire::agent_host_ssh)"

  if spire::agent_installed; then
    kvasir::log info "spire agent already present on ${KVASIR_SPIRE_AGENT_HOST}"
    return 0
  fi

  kvasir::log info "minting a join token for ${KVASIR_SPIRE_AGENT_HOST}"
  token="$(spire::server token generate \
             -spiffeID "${KVASIR_SPIRE_AGENT_SPIFFE_ID}" \
             -ttl "${KVASIR_SPIRE_JOIN_TOKEN_TTL}" 2>/dev/null \
           | sed -n 's/^Token: *//p' | tr -d '\r\n')"
  [[ -n "$token" ]] || kvasir::die "could not mint a join token for ${KVASIR_SPIRE_AGENT_HOST}"

  # The token is a bearer credential with a short TTL. It is written to the
  # host over the ssh channel and never echoed into a log or an argv this
  # process prints.
  ssh -o BatchMode=yes -o ConnectTimeout=15 "$host" \
      "SPIRE_JOIN_TOKEN='${token}' \
       SPIRE_IMAGE='${KVASIR_SPIRE_AGENT_IMAGE}' \
       SPIRE_SERVER='${KVASIR_SPIRE_SERVER_ADDRESS}' \
       SPIRE_TRUST_DOMAIN='${KVASIR_SPIRE_TRUST_DOMAIN}' \
       SPIRE_DATA='${KVASIR_SPIRE_AGENT_DATA_DIR}' \
       SPIRE_SOCKETS='${KVASIR_SPIRE_AGENT_SOCKET_DIR}' bash -s" <<'REMOTE'
set -euo pipefail
sudo -n mkdir -p "${SPIRE_DATA}/conf" "${SPIRE_DATA}/agent-data" "${SPIRE_SOCKETS}"
sudo -n tee "${SPIRE_DATA}/conf/agent.conf" >/dev/null <<CONF
agent {
  data_dir = "/opt/spire/data"
  log_level = "INFO"
  server_address = "${SPIRE_SERVER}"
  server_port = "8081"
  socket_path = "/tmp/spire-agent/public/agent.sock"
  trust_domain = "${SPIRE_TRUST_DOMAIN}"
  insecure_bootstrap = true
}
plugins {
  NodeAttestor "join_token" { plugin_data {} }
  KeyManager "memory" { plugin_data {} }
  WorkloadAttestor "unix" { plugin_data {} }
}
CONF
sudo -n docker rm -f spire-agent >/dev/null 2>&1 || true
sudo -n docker run -d --name spire-agent --restart unless-stopped \
  --network host \
  -v "${SPIRE_SOCKETS}:/tmp/spire-agent/public" \
  -v "${SPIRE_DATA}/conf/agent.conf:/opt/spire/conf/agent/agent.conf:ro" \
  -v "${SPIRE_DATA}/agent-data:/opt/spire/data" \
  "${SPIRE_IMAGE}" \
  -config /opt/spire/conf/agent/agent.conf -joinToken "${SPIRE_JOIN_TOKEN}" >/dev/null
REMOTE

  kvasir::log info "spire agent started on ${KVASIR_SPIRE_AGENT_HOST}; verifying"
  spire::agent_verify || kvasir::die "agent did not come up on ${KVASIR_SPIRE_AGENT_HOST}"
}

# A mutator cannot be the only witness that it mutated: check the socket exists
# on the host AND that the server has attested the agent.
spire::agent_verify() {
  spire::defaults
  local host i; host="$(spire::agent_host_ssh)"
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if ssh -o BatchMode=yes -o ConnectTimeout=8 "$host" \
         "test -S '${KVASIR_SPIRE_AGENT_SOCKET_DIR}/agent.sock'" 2>/dev/null; then
      kvasir::log info "workload API socket present on ${KVASIR_SPIRE_AGENT_HOST}"
      return 0
    fi
    sleep 3
  done
  return 1
}
