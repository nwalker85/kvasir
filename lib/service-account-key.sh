#!/usr/bin/env bash
# Helpers for host-scoped service-account SSH key material.

service_account::read_private_key() {
  local item="$1" vault="$2"
  op item get "$item" --vault "$vault" --format json 2>/dev/null \
    | jq -er '
        first(
          .fields[]
          | select(
              .id == "password"
              or .label == "password"
              or .id == "private-key"
              or .label == "private-key"
              or .id == "ssh-private-key"
              or .label == "ssh-private-key"
              or .label == "private SSH key"
            )
          | .value
          | select(. != null and . != "")
        )
      ' 2>/dev/null
}

service_account::write_private_key_file() {
  local uid="$1" private_key="$2"
  local key_file
  key_file="$(mktemp "${TMPDIR:-/tmp}/kvasir-${uid}.XXXXXX")"
  chmod 600 "$key_file"
  printf '%s\n' "$private_key" | sed 's/\[password\]$//' >"$key_file"
  printf '%s' "$key_file"
}

service_account::derive_public_key() {
  local key_file="$1"
  ssh-keygen -y -f "$key_file"
}
