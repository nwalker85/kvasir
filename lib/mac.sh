#!/usr/bin/env bash
# Kvasir macOS helpers — sourced from bin/enroll-host when target uname=Darwin.
# Provides Apple Directory Services binding to FreeIPA + Heimdal Kerberos
# config + sudoers fragment rendered from IPA sudo rules.
#
# See docs/mac-enrollment-design.md for the full design.

# All functions namespaced mac:: (public) or mac::_ (internal).

# ---------- pure renderers (no side effects, easy to test) ----------

# Render /etc/krb5.conf content. Args: <realm> <domain> <kdc-fqdn>
mac::_render_krb5_conf() {
  local realm="$1" domain="$2" kdc="$3"
  cat <<EOF
# Managed by kvasir — DO NOT EDIT.
# Re-run \`kvasir enroll-host <short> --apply\` to regenerate.
[libdefaults]
  default_realm = ${realm}
  dns_lookup_realm = false
  dns_lookup_kdc = true
  ticket_lifetime = 24h
  renew_lifetime = 7d
  forwardable = true
  rdns = false

[realms]
  ${realm} = {
    kdc = ${kdc}
    master_kdc = ${kdc}
    admin_server = ${kdc}
    default_domain = ${domain}
    pkinit_anchors = FILE:/etc/openldap/cacert.pem
  }

[domain_realm]
  .${domain} = ${realm}
  ${domain} = ${realm}
EOF
}

# Render the LDAPv3 OpenDirectory plist content. Args: <freeipa-fqdn> <domain>
#
# Maps FreeIPA's cn=accounts subtree to Apple's expected DS attributes
# (RFC2307). Uses anonymous bind for read; if FreeIPA's ACI blocks anon
# reads of required attrs on a hardened deployment, swap to a low-priv
# bind DN (set BindDN/BindCredentials keys — left empty here).
mac::_render_ldap_plist() {
  local fqdn="$1" domain="$2"
  local search_base="cn=accounts,dc=${domain//./,dc=}"
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>description</key>
  <string>FreeIPA (${fqdn}) — managed by kvasir</string>
  <key>options</key>
  <dict>
    <key>SSLEnabledKey</key>
    <true/>
    <key>Connection Setup Timeout</key>
    <integer>15</integer>
    <key>Connection Idle Timeout</key>
    <integer>120</integer>
  </dict>
  <key>readonly</key>
  <false/>
  <key>template</key>
  <string>RFC2307</string>
  <key>hostname</key>
  <string>${fqdn}</string>
  <key>port</key>
  <integer>636</integer>
  <key>SSLEnabledKey</key>
  <true/>
  <key>BindDN</key>
  <string></string>
  <key>BindCredentials</key>
  <string></string>
  <key>recordTypes</key>
  <dict>
    <key>Users</key>
    <dict>
      <key>Search Base</key>
      <string>${search_base}</string>
      <key>Object Classes</key>
      <array>
        <string>posixAccount</string>
        <string>inetOrgPerson</string>
      </array>
      <key>Native</key>
      <dict>
        <key>RecordName</key>
        <string>uid</string>
        <key>UniqueID</key>
        <string>uidNumber</string>
        <key>PrimaryGroupID</key>
        <string>gidNumber</string>
        <key>NFSHomeDirectory</key>
        <string>homeDirectory</string>
        <key>UserShell</key>
        <string>loginShell</string>
        <key>RealName</key>
        <string>cn</string>
        <key>EMailAddress</key>
        <string>mail</string>
      </dict>
    </dict>
    <key>Groups</key>
    <dict>
      <key>Search Base</key>
      <string>${search_base}</string>
      <key>Object Classes</key>
      <array>
        <string>posixGroup</string>
      </array>
      <key>Native</key>
      <dict>
        <key>RecordName</key>
        <string>cn</string>
        <key>PrimaryGroupID</key>
        <string>gidNumber</string>
        <key>GroupMembership</key>
        <string>memberUid</string>
      </dict>
    </dict>
  </dict>
</dict>
</plist>
EOF
}

# Render the sudoers fragment that grants nwalker passwordless root.
# Args: <user> <short-hostname>
mac::_render_sudoers_fragment() {
  local user="$1" short="$2"
  local stamp
  stamp="$(date -u +%FT%TZ)"
  cat <<EOF
# Managed by kvasir — DO NOT EDIT.
# Re-run \`kvasir enroll-host ${short} --apply\` to sync with IPA sudo rule
# kvasir-root-${short}. Last generated: ${stamp}.
${user} ALL=(root) NOPASSWD: ALL
EOF
}

# Confirm that an IPA sudo rule kvasir-root-<short> exists. Returns 0 if
# present, nonzero otherwise. Used as a precheck before writing the local
# sudoers fragment — if the rule isn't there, the IPA host record probably
# wasn't bootstrapped properly and we shouldn't grant local root.
# Args: <short-hostname>
mac::_verify_ipa_sudo_rule_exists() {
  local short="$1"
  ipa::cmd sudorule-show "kvasir-root-${short}" >/dev/null 2>&1
}

# Probe the target for pre-existing enrollment state. Returns:
#   0 — fully enrolled (keytab principal + LDAPv3 plist + sudoers fragment all present) → refresh OK
#   1 — clean (none of the artifacts present) → fresh install
#   2 — partial (some but not all) → require --force-reenroll
# Args: <ssh-host> <fqdn>
mac::_should_refresh() {
  local host="$1" fqdn="$2"
  local short="${fqdn%%.*}"
  local has_keytab=0 has_plist=0 has_sudoers=0

  if ssh -o BatchMode=yes "$host" "klist -k /etc/krb5.keytab 2>/dev/null | grep -q 'host/${fqdn}'"; then
    has_keytab=1
  fi
  if ssh -o BatchMode=yes "$host" "test -f /Library/Preferences/OpenDirectory/Configurations/LDAPv3/${KVASIR_FREEIPA_FQDN}.plist" 2>/dev/null; then
    has_plist=1
  fi
  if ssh -o BatchMode=yes "$host" "test -f /etc/sudoers.d/kvasir-managed-${short}" 2>/dev/null; then
    has_sudoers=1
  fi

  local total=$(( has_keytab + has_plist + has_sudoers ))
  if (( total == 3 )); then
    return 0
  elif (( total == 0 )); then
    return 1
  else
    return 2
  fi
}

# ---------- enrollment steps ----------

# Probe the target: confirm Darwin, capture sw_vers + IP.
# Args: <ssh-host>
# Echoes a single line: "<sw_vers>|<lan-ip>"
mac::probe_target() {
  local host="$1"
  local kernel
  kernel="$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" 'uname -s')" \
    || kvasir::die "cannot ssh to ${host}"
  [[ "$kernel" == "Darwin" ]] || kvasir::die "mac::probe_target: expected Darwin, got ${kernel}"

  local sw_vers ip
  sw_vers="$(ssh "$host" 'sw_vers -productVersion 2>/dev/null')"
  ip="$(ssh "$host" 'ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null')"
  [[ -n "$ip" ]] || kvasir::die "mac::probe_target: could not detect LAN IP on en0/en1"

  printf '%s|%s\n' "$sw_vers" "$ip"
}

# Stage /etc/krb5.conf on target. Backs up any pre-existing non-kvasir file.
# Args: <ssh-host>
mac::stage_krb5_conf() {
  local host="$1"
  local content
  content="$(mac::_render_krb5_conf \
    "${KVASIR_FREEIPA_REALM}" \
    "${KVASIR_FREEIPA_DOMAIN}" \
    "${KVASIR_FREEIPA_FQDN}")"

  if kvasir::is_dry_run; then
    kvasir::log info "DRY: would write /etc/krb5.conf on ${host} (backup pre-existing)"
    return 0
  fi

  # Backup if existing AND not kvasir-managed
  kvasir::ssh_sudo "$host" "bash -c '
    if [[ -f /etc/krb5.conf ]] && ! grep -q \"Managed by kvasir\" /etc/krb5.conf; then
      cp /etc/krb5.conf /etc/krb5.conf.kvasir-bak.\$(date +%s)
    fi
    cat > /etc/krb5.conf.kvasir-tmp <<\"EOF\"
${content}
EOF
    install -m 0644 -o root -g wheel /etc/krb5.conf.kvasir-tmp /etc/krb5.conf
    rm -f /etc/krb5.conf.kvasir-tmp
  '"
  kvasir::log info "  /etc/krb5.conf staged on ${host}"
}

# Mint host keytab via ipa::host_keytab, decode, install at /etc/krb5.keytab.
# Caller must have run ipa::admin_kinit_in_container first.
# Args: <ssh-host> <fqdn>
mac::install_host_keytab() {
  local host="$1" fqdn="$2"

  if kvasir::is_dry_run; then
    kvasir::log info "DRY: would mint host keytab for ${fqdn} and install at ${host}:/etc/krb5.keytab"
    return 0
  fi

  local keytab_b64
  keytab_b64="$(ipa::host_keytab "$fqdn")" \
    || kvasir::die "ipa::host_keytab failed for ${fqdn}"
  [[ -n "$keytab_b64" ]] || kvasir::die "ipa::host_keytab returned empty for ${fqdn}"

  # Pipe base64 through ssh; decode on target and install atomically.
  printf '%s' "$keytab_b64" | kvasir::ssh_sudo "$host" "bash -c '
    base64 -D > /tmp/kvasir.keytab
    chmod 0600 /tmp/kvasir.keytab
    install -m 0600 -o root -g wheel /tmp/kvasir.keytab /etc/krb5.keytab
    rm -f /tmp/kvasir.keytab
  '"

  # Validate principal landed
  local found
  found="$(ssh "$host" "sudo klist -k /etc/krb5.keytab 2>/dev/null | grep -c 'host/${fqdn}'")"
  (( found > 0 )) || kvasir::die "host principal not found in keytab after install"
  kvasir::log info "  /etc/krb5.keytab installed; host/${fqdn} principal present"
}
