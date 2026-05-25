#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/lib/common.sh"
source "${ROOT}/lib/mac.sh"

# ---- mac::_render_krb5_conf ----
test::render_krb5_conf::has_default_realm() {
  local output
  output=$(mac::_render_krb5_conf "RAVENHELM.DEV" "ravenhelm.dev" "ipa.ravenhelm.dev")
  grep -qE '^[[:space:]]*default_realm[[:space:]]*=[[:space:]]*RAVENHELM\.DEV' <<<"$output" \
    || { printf 'FAIL: default_realm missing or wrong\n%s\n' "$output" >&2; return 1; }
  printf 'PASS: render_krb5_conf::has_default_realm\n'
}

test::render_krb5_conf::has_realms_section() {
  local output
  output=$(mac::_render_krb5_conf "RAVENHELM.DEV" "ravenhelm.dev" "ipa.ravenhelm.dev")
  grep -q '^\[realms\]' <<<"$output" \
    || { printf 'FAIL: [realms] missing\n%s\n' "$output" >&2; return 1; }
  grep -qE 'kdc[[:space:]]*=[[:space:]]*ipa\.ravenhelm\.dev' <<<"$output" \
    || { printf 'FAIL: kdc entry missing\n%s\n' "$output" >&2; return 1; }
  printf 'PASS: render_krb5_conf::has_realms_section\n'
}

test::render_krb5_conf::has_domain_realm_mapping() {
  local output
  output=$(mac::_render_krb5_conf "RAVENHELM.DEV" "ravenhelm.dev" "ipa.ravenhelm.dev")
  grep -q '^\[domain_realm\]' <<<"$output" \
    || { printf 'FAIL: [domain_realm] missing\n%s\n' "$output" >&2; return 1; }
  grep -qE '\.ravenhelm\.dev[[:space:]]*=[[:space:]]*RAVENHELM\.DEV' <<<"$output" \
    || { printf 'FAIL: domain→realm mapping missing\n%s\n' "$output" >&2; return 1; }
  printf 'PASS: render_krb5_conf::has_domain_realm_mapping\n'
}

test::render_krb5_conf::has_default_realm
test::render_krb5_conf::has_realms_section
test::render_krb5_conf::has_domain_realm_mapping
