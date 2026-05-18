#!/usr/bin/env bash
# 1Password CLI helpers. Requires `op` signed in.

# Read a single field from a 1P item. Always works even in dry-run (read-only).
op::read_field() {
  local item="$1" field="$2" vault="${3:-${KVASIR_OP_VAULT:-ravenmask}}"
  op item get "$item" --vault "$vault" --fields "$field" --reveal 2>/dev/null \
    || kvasir::die "1P read failed: $vault / $item / $field"
}

# Test whether a 1P item exists (no secret leakage on failure).
op::item_exists() {
  local item="$1" vault="${2:-${KVASIR_OP_VAULT:-ravenmask}}"
  op item get "$item" --vault "$vault" --format json >/dev/null 2>&1
}

# Create a 1P login item with arbitrary fields.
# Usage: op::create_item TITLE [vault] field1=val1 field2=val2 ...
# Field type defaults to text. Prefix with `concealed:` to mark as password.
# Example: op::create_item "FreeIPA Host vakr" ravenmask \
#            username=host/vakr.ravenhelm.dev \
#            concealed:otp=$OTP \
#            url=https://ipa.ravenhelm.dev
op::create_item() {
  local title="$1" vault="$2"; shift 2
  if op::item_exists "$title" "$vault"; then
    kvasir::log warn "1P item already exists: $vault / $title — skipping create"
    return 0
  fi
  local args=()
  for kv in "$@"; do
    if [[ "$kv" == concealed:* ]]; then
      args+=( "${kv#concealed:}[password]" )
    else
      args+=( "$kv" )
    fi
  done
  if kvasir::is_dry_run; then
    kvasir::log info "DRY: op item create --vault $vault --title '$title' --category login [${#args[@]} fields]"
    return 0
  fi
  op item create --category login --vault "$vault" --title "$title" "${args[@]}" >/dev/null
  kvasir::log info "1P item created: $vault / $title"
}

# Upsert a single concealed field on an existing item.
op::set_field() {
  local item="$1" field="$2" value="$3" vault="${4:-${KVASIR_OP_VAULT:-ravenmask}}"
  if kvasir::is_dry_run; then
    kvasir::log info "DRY: op item edit '$item' '${field}[password]=***' --vault $vault"
    return 0
  fi
  op item edit "$item" --vault "$vault" "${field}[password]=${value}" >/dev/null
  kvasir::log info "1P field updated: $vault / $item / $field"
}
