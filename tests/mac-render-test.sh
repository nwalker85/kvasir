#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/lib/common.sh"
source "${ROOT}/lib/op.sh"
source "${ROOT}/lib/freeipa.sh"
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

# ---- mac::_render_ldap_plist ----
test::render_ldap_plist::is_valid_plist() {
  local output
  output=$(mac::_render_ldap_plist "ipa.ravenhelm.dev" "ravenhelm.dev")
  if ! command -v plutil >/dev/null 2>&1; then
    printf 'SKIP: render_ldap_plist::is_valid_plist (no plutil)\n'
    return 0
  fi
  if ! echo "$output" | plutil -lint -s - >/dev/null 2>&1; then
    printf 'FAIL: plist did not pass plutil -lint\n%s\n' "$output" >&2
    return 1
  fi
  printf 'PASS: render_ldap_plist::is_valid_plist\n'
}

test::render_ldap_plist::has_server_host() {
  local output
  output=$(mac::_render_ldap_plist "ipa.ravenhelm.dev" "ravenhelm.dev")
  grep -q '<string>ipa.ravenhelm.dev</string>' <<<"$output" \
    || { printf 'FAIL: server host missing\n' >&2; return 1; }
  printf 'PASS: render_ldap_plist::has_server_host\n'
}

test::render_ldap_plist::has_rfc2307_mapping() {
  local output
  output=$(mac::_render_ldap_plist "ipa.ravenhelm.dev" "ravenhelm.dev")
  grep -q '<string>uidNumber</string>' <<<"$output" \
    || { printf 'FAIL: uidNumber mapping missing\n' >&2; return 1; }
  grep -q '<string>gidNumber</string>' <<<"$output" \
    || { printf 'FAIL: gidNumber mapping missing\n' >&2; return 1; }
  grep -q '<string>homeDirectory</string>' <<<"$output" \
    || { printf 'FAIL: homeDirectory mapping missing\n' >&2; return 1; }
  printf 'PASS: render_ldap_plist::has_rfc2307_mapping\n'
}

test::render_ldap_plist::has_tls_enabled() {
  local output
  output=$(mac::_render_ldap_plist "ipa.ravenhelm.dev" "ravenhelm.dev")
  grep -q '<key>SSLEnabledKey</key>' <<<"$output" \
    || { printf 'FAIL: SSLEnabledKey missing\n' >&2; return 1; }
  printf 'PASS: render_ldap_plist::has_tls_enabled\n'
}

# ---- mac::_render_sudoers_fragment ----
test::render_sudoers::passes_visudo() {
  local output
  output=$(mac::_render_sudoers_fragment "nwalker" "odin")
  if ! command -v visudo >/dev/null 2>&1; then
    printf 'SKIP: render_sudoers::passes_visudo (no visudo)\n'
    return 0
  fi
  local tmp
  tmp=$(mktemp)
  printf '%s\n' "$output" > "$tmp"
  if ! visudo -cf "$tmp" >/dev/null 2>&1; then
    printf 'FAIL: visudo -cf rejected fragment\n%s\n' "$output" >&2
    rm -f "$tmp"
    return 1
  fi
  rm -f "$tmp"
  printf 'PASS: render_sudoers::passes_visudo\n'
}

test::render_sudoers::grants_nopasswd() {
  local output
  output=$(mac::_render_sudoers_fragment "nwalker" "odin")
  grep -qE '^nwalker[[:space:]]+ALL=\(root\)[[:space:]]+NOPASSWD:[[:space:]]+ALL' <<<"$output" \
    || { printf 'FAIL: nopasswd grant line missing\n%s\n' "$output" >&2; return 1; }
  printf 'PASS: render_sudoers::grants_nopasswd\n'
}

test::render_sudoers::has_managed_header() {
  local output
  output=$(mac::_render_sudoers_fragment "nwalker" "odin")
  grep -q 'Managed by kvasir' <<<"$output" \
    || { printf 'FAIL: managed header missing\n' >&2; return 1; }
  grep -q 'kvasir enroll-host odin' <<<"$output" \
    || { printf 'FAIL: re-run hint missing\n' >&2; return 1; }
  printf 'PASS: render_sudoers::has_managed_header\n'
}

# ---- mac::_verify_ipa_sudo_rule_exists ----
test::verify_ipa_sudo_rule_exists::returns_ok_when_present() {
  ipa::cmd() {
    if [[ "$1" == "sudorule-show" && "$2" == "kvasir-root-odin" ]]; then
      printf 'Rule name: kvasir-root-odin\n'
      return 0
    fi
    return 1
  }
  if mac::_verify_ipa_sudo_rule_exists "odin"; then
    printf 'PASS: verify_ipa_sudo_rule_exists::returns_ok_when_present\n'
  else
    printf 'FAIL: should have returned 0\n' >&2
    return 1
  fi
}

test::verify_ipa_sudo_rule_exists::fails_when_absent() {
  ipa::cmd() { return 1; }
  if mac::_verify_ipa_sudo_rule_exists "ghost"; then
    printf 'FAIL: should have returned nonzero\n' >&2
    return 1
  fi
  printf 'PASS: verify_ipa_sudo_rule_exists::fails_when_absent\n'
}

test::render_krb5_conf::has_default_realm
test::render_krb5_conf::has_realms_section
test::render_krb5_conf::has_domain_realm_mapping
test::render_ldap_plist::is_valid_plist
test::render_ldap_plist::has_server_host
test::render_ldap_plist::has_rfc2307_mapping
test::render_ldap_plist::has_tls_enabled
test::render_sudoers::passes_visudo
test::render_sudoers::grants_nopasswd
test::render_sudoers::has_managed_header
test::verify_ipa_sudo_rule_exists::returns_ok_when_present
test::verify_ipa_sudo_rule_exists::fails_when_absent
