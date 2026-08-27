#!/usr/bin/env bash
# Local enrollment receipts. No secret-bearing keys allowed.

receipt::dir() {
  printf '%s/kvasir/receipts\n' "${XDG_STATE_HOME:-${HOME}/.local/state}"
}

receipt::forbidden_key() {
  local key="$1"
  [[ "$key" =~ (password|token|keytab|private_key|credential|secret|join_token) ]]
}

receipt::assert_safe_file() {
  local file="$1"
  local key
  command -v jq >/dev/null 2>&1 || kvasir::die "jq is required to validate receipts"
  while IFS= read -r key; do
    if receipt::forbidden_key "$key"; then
      kvasir::die "receipt contains forbidden key: ${key}"
    fi
  done < <(jq -r 'paths(scalars) | map(tostring) | join(".")' "$file")
}

receipt::write() {
  local id="$1" json="$2"
  local dir dest tmp
  dir="$(receipt::dir)"
  dest="${dir}/${id}.json"
  tmp="${dest}.tmp"
  mkdir -p "${dir}"
  umask 077
  printf '%s\n' "$json" >"${tmp}"
  receipt::assert_safe_file "${tmp}"
  mv "${tmp}" "${dest}"
  kvasir::log info "receipt: ${dest}"
  printf '%s\n' "$dest"
}

receipt::get() {
  local id="$1"
  local dest
  dest="$(receipt::dir)/${id}.json"
  [[ -f "$dest" ]] || kvasir::die "no receipt ${id}"
  receipt::assert_safe_file "$dest"
  cat "$dest"
}
