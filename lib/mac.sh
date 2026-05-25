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
