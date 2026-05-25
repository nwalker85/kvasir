# macOS host enrollment — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend `kvasir enroll-host` so `kvasir enroll-host odin --apply` and `kvasir enroll-host skoll --apply` produce an Apple Silicon macOS host bound to FreeIPA — identity (`id nwalker` resolves), Kerberos SSO (host keytab installed, `kinit nwalker` works), and a kvasir-managed sudoers fragment granting nwalker passwordless root.

**Architecture:** New `lib/mac.sh` holds all macOS-specific logic, namespaced `mac::*` (mirrors existing `ipa::*`/`op::*` pattern). `bin/enroll-host` dispatches to `mac::enroll` when `uname -s` on the target returns `Darwin`; Linux flow is untouched. One new helper `ipa::host_keytab` added to `lib/freeipa.sh`. Existing `kvasir::ssh_sudo`, `kvasir::is_dry_run`, `kvasir::log` reused throughout.

**Tech Stack:** Bash 3.2+, Apple Heimdal Kerberos (`/usr/bin/kinit`, `/usr/bin/klist`), Apple Directory Services (`dscl`, `opendirectoryd`, OpenDirectory plist), FreeIPA `ipa-getkeytab` (run in container on hrafngud), 1Password CLI `op`, `visudo`, `plutil`.

**Spec:** [`docs/mac-enrollment-design.md`](mac-enrollment-design.md)

---

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `lib/freeipa.sh` | Modify | Add `ipa::host_keytab` — mints + returns base64 keytab via container |
| `lib/mac.sh` | Create | All macOS enrollment logic (`mac::enroll`, renderers, steps, uninstall) |
| `bin/enroll-host` | Modify | Add Darwin branch after target probe, dispatch to `mac::enroll` |
| `tests/mac-render-test.sh` | Create | Pure-local unit tests for renderers (no SSH/IPA) |
| `tests/mac-state-detection-test.sh` | Create | Stub-based tests for `mac::_should_refresh` |
| `tests/mac-enroll-host-integration-test.sh` | Create | End-to-end test, gated by env var |
| `README.md` | Modify | Add macOS row to command table |

`lib/mac.sh` size budget: ~400-500 lines. If it grows beyond, split into `lib/mac.sh` (orchestration) + `lib/mac-render.sh` (pure renderers) — deferred until size demands.

---

## Task 1: Add `ipa::host_keytab` helper

**Files:**
- Modify: `lib/freeipa.sh:378-380` (append before final `ipa::ca_cert` function, or after — keep CA cert function as the file's tail)

- [ ] **Step 1: Write the test**

Create `tests/ipa-host-keytab-test.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
STUB_DIR="${TMPDIR}/bin"
mkdir -p "${STUB_DIR}"
trap 'rm -rf "${TMPDIR}"' EXIT

cat >"${TMPDIR}/kvasir.env" <<'ENV'
KVASIR_FREEIPA_HOST="hrafngud-ts-svc"
KVASIR_FREEIPA_CONTAINER="freeipa"
KVASIR_FREEIPA_DOMAIN="ravenhelm.dev"
KVASIR_FREEIPA_REALM="RAVENHELM.DEV"
KVASIR_DRY_RUN=0
KVASIR_LOG_LEVEL=error
ENV

# Stub ssh: capture the docker exec command, emit canned base64 keytab
cat >"${STUB_DIR}/ssh" <<'STUB'
#!/usr/bin/env bash
# Simulate ipa-getkeytab → keytab bytes → base64 transport pipeline
if [[ "$*" == *"ipa-getkeytab"*"host/odin.ravenhelm.dev"* ]]; then
  printf 'AAEACgADAAxLRVlUQUItQllURVMK'  # 28 chars of fake base64
  exit 0
fi
printf 'unexpected ssh args: %s\n' "$*" >&2
exit 64
STUB
chmod +x "${STUB_DIR}/ssh"

cat >"${STUB_DIR}/op" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "${STUB_DIR}/op"

export PATH="${STUB_DIR}:${PATH}"
export KVASIR_ENV_FILE="${TMPDIR}/kvasir.env"

source "${ROOT}/lib/common.sh"
source "${ROOT}/lib/op.sh"
source "${ROOT}/lib/freeipa.sh"

kvasir::load_env

OUTPUT="$(ipa::host_keytab "odin.ravenhelm.dev")"
if [[ "$OUTPUT" != "AAEACgADAAxLRVlUQUItQllURVMK" ]]; then
  printf 'FAIL: expected canned keytab, got: %s\n' "$OUTPUT" >&2
  exit 1
fi
printf 'PASS: ipa::host_keytab returns base64-wrapped keytab\n'
```

Make executable:

```bash
chmod +x tests/ipa-host-keytab-test.sh
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/ipa-host-keytab-test.sh`
Expected: error like `bash: ipa::host_keytab: command not found` (function doesn't exist yet)

- [ ] **Step 3: Implement `ipa::host_keytab`**

Append to `lib/freeipa.sh` (before the closing of the file, after `ipa::ca_cert`):

```bash
# Mint a fresh host keytab for $FQDN inside the freeipa container and emit
# it as base64 on stdout. Caller must have run ipa::admin_kinit_in_container
# first (so ipa-getkeytab can authenticate). Each call rotates the host's
# kvno — matches Linux enroll-host's re-run-as-rotation semantics.
# Args: <fqdn>
ipa::host_keytab() {
  local fqdn="$1"
  local cmd
  cmd="ipa-getkeytab -p host/${fqdn} -k /tmp/${fqdn}.keytab >/dev/null"
  cmd+=" && base64 < /tmp/${fqdn}.keytab"
  cmd+=" && rm -f /tmp/${fqdn}.keytab"
  ipa::docker_exec "$cmd"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/ipa-host-keytab-test.sh`
Expected: `PASS: ipa::host_keytab returns base64-wrapped keytab`

- [ ] **Step 5: Commit**

```bash
cd /Users/nate/src/platforms/ravenhelm/.kvasir-worktrees/mac-enrollment-design
git add lib/freeipa.sh tests/ipa-host-keytab-test.sh
git commit -m "$(cat <<'EOF'
feat(freeipa): add ipa::host_keytab helper

Mints + returns a base64-encoded host keytab via the freeipa container.
First consumer is the upcoming macOS enrollment flow which needs to
install a host keytab at /etc/krb5.keytab for Kerberos SSO.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Create `lib/mac.sh` skeleton + `mac::_render_krb5_conf`

**Files:**
- Create: `lib/mac.sh`
- Create: `tests/mac-render-test.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/mac-render-test.sh`:

```bash
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
```

Make executable: `chmod +x tests/mac-render-test.sh`

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/mac-render-test.sh`
Expected: error like `No such file or directory: lib/mac.sh`

- [ ] **Step 3: Create `lib/mac.sh` with skeleton + first renderer**

```bash
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/mac-render-test.sh`
Expected:
```
PASS: render_krb5_conf::has_default_realm
PASS: render_krb5_conf::has_realms_section
PASS: render_krb5_conf::has_domain_realm_mapping
```

- [ ] **Step 5: Commit**

```bash
git add lib/mac.sh tests/mac-render-test.sh
git commit -m "$(cat <<'EOF'
feat(mac): add lib/mac.sh skeleton + krb5.conf renderer

First piece of macOS enrollment support. Pure renderer with TDD tests
that assert required sections/keys are present. No side effects yet.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Add `mac::_render_ldap_plist`

**Files:**
- Modify: `lib/mac.sh` (append after `mac::_render_krb5_conf`)
- Modify: `tests/mac-render-test.sh` (append tests)

- [ ] **Step 1: Add failing tests to `tests/mac-render-test.sh`**

Append before the final test invocations:

```bash
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
```

Add these invocations at the end:

```bash
test::render_ldap_plist::is_valid_plist
test::render_ldap_plist::has_server_host
test::render_ldap_plist::has_rfc2307_mapping
test::render_ldap_plist::has_tls_enabled
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/mac-render-test.sh`
Expected: failure at first new test (function not defined)

- [ ] **Step 3: Append `mac::_render_ldap_plist` to `lib/mac.sh`**

```bash
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
```

- [ ] **Step 4: Run tests**

Run: `bash tests/mac-render-test.sh`
Expected: All four new tests PASS (plus existing 3).

- [ ] **Step 5: Commit**

```bash
git add lib/mac.sh tests/mac-render-test.sh
git commit -m "$(cat <<'EOF'
feat(mac): add LDAPv3 plist renderer with RFC2307 mapping

Produces the OpenDirectory plist that opendirectoryd reads to bind to
FreeIPA's cn=accounts subtree. RFC2307 mapping matches FreeIPA's native
schema. TLS required on port 636. Bind DN/credentials left empty —
anonymous bind first; fall back to low-priv DN if hardened ACI blocks.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Add `mac::_render_sudoers_fragment`

**Files:**
- Modify: `lib/mac.sh`
- Modify: `tests/mac-render-test.sh`

- [ ] **Step 1: Add failing tests**

Append to `tests/mac-render-test.sh` (before the test invocations at the bottom):

```bash
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
```

Add invocations at end:

```bash
test::render_sudoers::passes_visudo
test::render_sudoers::grants_nopasswd
test::render_sudoers::has_managed_header
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/mac-render-test.sh`
Expected: failure (function not defined)

- [ ] **Step 3: Append `mac::_render_sudoers_fragment` to `lib/mac.sh`**

```bash
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
```

- [ ] **Step 4: Run tests**

Run: `bash tests/mac-render-test.sh`
Expected: All new tests PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/mac.sh tests/mac-render-test.sh
git commit -m "$(cat <<'EOF'
feat(mac): add sudoers fragment renderer

Renders /etc/sudoers.d/kvasir-managed-<short> content with a managed
header and a passwordless root grant for the FreeIPA user. Validated
inline with visudo before install in the real flow.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Add `mac::_verify_ipa_sudo_rule_exists`

**Files:**
- Modify: `lib/mac.sh`
- Modify: `tests/mac-render-test.sh`

- [ ] **Step 1: Add failing test**

Append to `tests/mac-render-test.sh` before invocations:

```bash
# ---- mac::_verify_ipa_sudo_rule_exists ----
# This function asks ipa::cmd whether kvasir-root-<short> exists.
# We stub ipa::cmd to return success or failure based on the rule name.
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
```

Add invocations + source freeipa.sh at top (so `ipa::cmd` exists to override):

In `tests/mac-render-test.sh`, near the top after the other `source` lines, add:

```bash
source "${ROOT}/lib/op.sh"
source "${ROOT}/lib/freeipa.sh"
```

Add invocations at end:

```bash
test::verify_ipa_sudo_rule_exists::returns_ok_when_present
test::verify_ipa_sudo_rule_exists::fails_when_absent
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/mac-render-test.sh`
Expected: failure on first new test (function not defined).

- [ ] **Step 3: Append `mac::_verify_ipa_sudo_rule_exists` to `lib/mac.sh`**

```bash
# Confirm that an IPA sudo rule kvasir-root-<short> exists. Returns 0 if
# present, nonzero otherwise. Used as a precheck before writing the local
# sudoers fragment — if the rule isn't there, the IPA host record probably
# wasn't bootstrapped properly and we shouldn't grant local root.
# Args: <short-hostname>
mac::_verify_ipa_sudo_rule_exists() {
  local short="$1"
  ipa::cmd sudorule-show "kvasir-root-${short}" >/dev/null 2>&1
}
```

- [ ] **Step 4: Run tests**

Run: `bash tests/mac-render-test.sh`
Expected: All tests PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/mac.sh tests/mac-render-test.sh
git commit -m "$(cat <<'EOF'
feat(mac): add IPA sudo rule existence check

Precheck called before writing the local sudoers fragment — confirms
kvasir-root-<short> exists in IPA. If absent, the host record probably
wasn't bootstrapped via ipa::service_account_ensure_root and writing a
local grant would be inappropriate.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Add `mac::_should_refresh` state detector

**Files:**
- Modify: `lib/mac.sh`
- Create: `tests/mac-state-detection-test.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/mac-state-detection-test.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
STUB_DIR="${TMPDIR}/bin"
mkdir -p "${STUB_DIR}"
trap 'rm -rf "${TMPDIR}"' EXIT

# ssh stub — behavior controlled by KVASIR_TEST_STATE env var
cat >"${STUB_DIR}/ssh" <<'STUB'
#!/usr/bin/env bash
state="${KVASIR_TEST_STATE:-clean}"
case "$state" in
  clean)
    exit 1  # nothing exists
    ;;
  fully-enrolled)
    if [[ "$*" == *"klist -k"* ]]; then
      printf 'Keytab name: FILE:/etc/krb5.keytab\nKVNO Principal\n----\n   1 host/odin.ravenhelm.dev@RAVENHELM.DEV\n'
      exit 0
    elif [[ "$*" == *"test -f /Library/Preferences/OpenDirectory"* ]]; then
      exit 0
    elif [[ "$*" == *"test -f /etc/sudoers.d/kvasir-managed-"* ]]; then
      exit 0
    fi
    exit 1
    ;;
  partial-keytab-only)
    if [[ "$*" == *"klist -k"* ]]; then
      printf '   1 host/odin.ravenhelm.dev@RAVENHELM.DEV\n'
      exit 0
    fi
    exit 1
    ;;
esac
exit 1
STUB
chmod +x "${STUB_DIR}/ssh"

export PATH="${STUB_DIR}:${PATH}"
source "${ROOT}/lib/common.sh"
source "${ROOT}/lib/mac.sh"

# Expected returns: 0=refresh, 1=clean install, 2=partial (require --force)
test::should_refresh::clean_returns_1() {
  KVASIR_TEST_STATE=clean
  local rc=0
  mac::_should_refresh "odin" "odin.ravenhelm.dev" || rc=$?
  if (( rc != 1 )); then
    printf 'FAIL: expected rc=1 for clean state, got %d\n' "$rc" >&2
    return 1
  fi
  printf 'PASS: should_refresh::clean_returns_1\n'
}

test::should_refresh::fully_enrolled_returns_0() {
  KVASIR_TEST_STATE=fully-enrolled
  local rc=0
  mac::_should_refresh "odin" "odin.ravenhelm.dev" || rc=$?
  if (( rc != 0 )); then
    printf 'FAIL: expected rc=0 for fully-enrolled, got %d\n' "$rc" >&2
    return 1
  fi
  printf 'PASS: should_refresh::fully_enrolled_returns_0\n'
}

test::should_refresh::partial_returns_2() {
  KVASIR_TEST_STATE=partial-keytab-only
  local rc=0
  mac::_should_refresh "odin" "odin.ravenhelm.dev" || rc=$?
  if (( rc != 2 )); then
    printf 'FAIL: expected rc=2 for partial state, got %d\n' "$rc" >&2
    return 1
  fi
  printf 'PASS: should_refresh::partial_returns_2\n'
}

test::should_refresh::clean_returns_1
test::should_refresh::fully_enrolled_returns_0
test::should_refresh::partial_returns_2
```

Make executable: `chmod +x tests/mac-state-detection-test.sh`

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/mac-state-detection-test.sh`
Expected: failure (function not defined).

- [ ] **Step 3: Append `mac::_should_refresh` to `lib/mac.sh`**

```bash
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
```

- [ ] **Step 4: Run tests**

Run: `KVASIR_FREEIPA_FQDN=ipa.ravenhelm.dev bash tests/mac-state-detection-test.sh`
Expected: All three states PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/mac.sh tests/mac-state-detection-test.sh
git commit -m "$(cat <<'EOF'
feat(mac): add state detector for pre-existing enrollment

Probes the target via ssh to check for keytab principal, LDAPv3 plist,
and kvasir sudoers fragment. Returns 0 (fully enrolled — refresh OK),
1 (clean — fresh install), or 2 (partial — require --force-reenroll).
Prevents accidentally corrupting half-enrolled hosts.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Add `mac::probe_target`

**Files:**
- Modify: `lib/mac.sh`

This step has no isolated unit test — it just wraps ssh probes. Coverage comes via the integration test in Task 16.

- [ ] **Step 1: Append to `lib/mac.sh`**

```bash
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
```

- [ ] **Step 2: Commit**

```bash
git add lib/mac.sh
git commit -m "$(cat <<'EOF'
feat(mac): add probe_target step

Confirms target is Darwin, captures sw_vers and en0/en1 IP. Dies on
non-Darwin (defensive — bin/enroll-host's dispatcher should prevent
this, but belt-and-suspenders).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Add `mac::stage_krb5_conf`

**Files:**
- Modify: `lib/mac.sh`

- [ ] **Step 1: Append to `lib/mac.sh`**

```bash
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
```

- [ ] **Step 2: Commit**

```bash
git add lib/mac.sh
git commit -m "$(cat <<'EOF'
feat(mac): add stage_krb5_conf step

Writes /etc/krb5.conf on target with realm config from env. Backs up
pre-existing non-kvasir krb5.conf to .kvasir-bak.<epoch> before
overwriting. Uses install(8) for atomic replacement.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: Add `mac::install_host_keytab`

**Files:**
- Modify: `lib/mac.sh`

- [ ] **Step 1: Append to `lib/mac.sh`**

```bash
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
```

- [ ] **Step 2: Commit**

```bash
git add lib/mac.sh
git commit -m "$(cat <<'EOF'
feat(mac): add install_host_keytab step

Mints fresh keytab via ipa::host_keytab (in container), transports
base64 over ssh, decodes on target, installs at /etc/krb5.keytab with
0600 root:wheel. Validates host principal landed via klist -k.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: Add `mac::stage_ca_cert`

**Files:**
- Modify: `lib/mac.sh`

- [ ] **Step 1: Append to `lib/mac.sh`**

```bash
# Install FreeIPA CA cert at /etc/openldap/cacert.pem (referenced by the
# LDAPv3 plist for TLS bind verification).
# Args: <ssh-host>
mac::stage_ca_cert() {
  local host="$1"

  if kvasir::is_dry_run; then
    kvasir::log info "DRY: would install FreeIPA CA cert at ${host}:/etc/openldap/cacert.pem"
    return 0
  fi

  local ca_pem
  ca_pem="$(ipa::ca_cert)" || kvasir::die "ipa::ca_cert failed"
  [[ -n "$ca_pem" ]] || kvasir::die "ipa::ca_cert returned empty"

  printf '%s' "$ca_pem" | kvasir::ssh_sudo "$host" "bash -c '
    install -d -m 0755 /etc/openldap
    cat > /tmp/kvasir.cacert
    install -m 0644 -o root -g wheel /tmp/kvasir.cacert /etc/openldap/cacert.pem
    rm -f /tmp/kvasir.cacert
  '"
  kvasir::log info "  /etc/openldap/cacert.pem installed"
}
```

- [ ] **Step 2: Commit**

```bash
git add lib/mac.sh
git commit -m "$(cat <<'EOF'
feat(mac): add stage_ca_cert step

Installs FreeIPA CA cert at /etc/openldap/cacert.pem. Referenced by the
LDAPv3 plist for TLS bind verification on port 636.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 11: Add `mac::bind_ldap`

**Files:**
- Modify: `lib/mac.sh`

- [ ] **Step 1: Append to `lib/mac.sh`**

```bash
# Write the LDAPv3 plist, add to opendirectoryd's CSPSearchPath, reload.
# Args: <ssh-host>
mac::bind_ldap() {
  local host="$1"
  local plist_path="/Library/Preferences/OpenDirectory/Configurations/LDAPv3/${KVASIR_FREEIPA_FQDN}.plist"
  local content
  content="$(mac::_render_ldap_plist "${KVASIR_FREEIPA_FQDN}" "${KVASIR_FREEIPA_DOMAIN}")"

  if kvasir::is_dry_run; then
    kvasir::log info "DRY: would write ${plist_path}, append to CSPSearchPath, reload opendirectoryd"
    return 0
  fi

  # Write plist + ensure parent dir
  kvasir::ssh_sudo "$host" "bash -c '
    install -d -m 0755 /Library/Preferences/OpenDirectory/Configurations/LDAPv3
    cat > /tmp/kvasir.ldap.plist <<\"EOF\"
${content}
EOF
    plutil -lint /tmp/kvasir.ldap.plist >/dev/null
    install -m 0600 -o root -g wheel /tmp/kvasir.ldap.plist \"${plist_path}\"
    rm -f /tmp/kvasir.ldap.plist
  '"

  # Add to search path if not already there
  kvasir::ssh_sudo "$host" "bash -c '
    if ! dscl /Search -read / CSPSearchPath 2>/dev/null | grep -q \"/LDAPv3/${KVASIR_FREEIPA_FQDN}\"; then
      dscl /Search -append / CSPSearchPath \"/LDAPv3/${KVASIR_FREEIPA_FQDN}\"
    fi
    if ! dscl /Search/Contacts -read / CSPSearchPath 2>/dev/null | grep -q \"/LDAPv3/${KVASIR_FREEIPA_FQDN}\"; then
      dscl /Search/Contacts -append / CSPSearchPath \"/LDAPv3/${KVASIR_FREEIPA_FQDN}\"
    fi
  '"

  # Reload opendirectoryd (launchd respawns immediately)
  kvasir::ssh_sudo "$host" "killall opendirectoryd 2>/dev/null || true"
  sleep 2
  kvasir::log info "  LDAPv3 bind to ${KVASIR_FREEIPA_FQDN} active"
}
```

- [ ] **Step 2: Commit**

```bash
git add lib/mac.sh
git commit -m "$(cat <<'EOF'
feat(mac): add bind_ldap step

Writes the LDAPv3 plist, validates with plutil before install, appends
the binding to opendirectoryd's CSPSearchPath (and Contacts search
path) if not already present, then reloads opendirectoryd via killall.
launchd auto-respawns.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 12: Add `mac::validate_identity`

**Files:**
- Modify: `lib/mac.sh`

- [ ] **Step 1: Append to `lib/mac.sh`**

```bash
# Validate identity resolution on the target. Hard-fails if id nwalker or
# dscl read are empty. Logs green checks on success.
# Args: <ssh-host> <fqdn>
mac::validate_identity() {
  local host="$1" fqdn="$2"

  if kvasir::is_dry_run; then
    kvasir::log info "DRY: would validate id nwalker / dscl / klist -k on ${host}"
    return 0
  fi

  local id_out dscl_out klist_out
  id_out="$(ssh "$host" "id nwalker 2>&1")"
  if ! [[ "$id_out" =~ uid=[0-9]+\(nwalker\) ]]; then
    kvasir::die "id nwalker failed on ${host}: ${id_out}"
  fi
  kvasir::log info "  ✓ ${id_out}"

  dscl_out="$(ssh "$host" "dscl . -read /Users/nwalker UniqueID 2>&1")"
  if ! [[ "$dscl_out" =~ UniqueID:[[:space:]]*[0-9]+ ]]; then
    kvasir::die "dscl . -read /Users/nwalker UniqueID failed: ${dscl_out}"
  fi
  kvasir::log info "  ✓ ${dscl_out}"

  klist_out="$(ssh "$host" "sudo klist -k /etc/krb5.keytab 2>&1 | grep 'host/${fqdn}'")"
  if [[ -z "$klist_out" ]]; then
    kvasir::die "host/${fqdn} not in /etc/krb5.keytab"
  fi
  kvasir::log info "  ✓ host principal present in keytab"
}
```

- [ ] **Step 2: Commit**

```bash
git add lib/mac.sh
git commit -m "$(cat <<'EOF'
feat(mac): add validate_identity step

Hard-fails if id nwalker doesn't resolve to a uid, dscl can't read
UniqueID, or host principal isn't in the keytab. Each successful check
logs a green checkmark. Matches Linux enroll-host's validation depth.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 13: Add `mac::write_sudoers`

**Files:**
- Modify: `lib/mac.sh`

- [ ] **Step 1: Append to `lib/mac.sh`**

```bash
# Render + install /etc/sudoers.d/kvasir-managed-<short> on target.
# Prechecks that the IPA sudo rule exists. Validates with visudo before
# installing. Backs up any prior non-kvasir fragment at the same path.
# Args: <ssh-host> <short-hostname>
mac::write_sudoers() {
  local host="$1" short="$2"
  local fragment_path="/etc/sudoers.d/kvasir-managed-${short}"

  if kvasir::is_dry_run; then
    kvasir::log info "DRY: would precheck IPA sudo rule kvasir-root-${short}, render + install ${fragment_path}"
    return 0
  fi

  mac::_verify_ipa_sudo_rule_exists "$short" \
    || kvasir::die "IPA sudo rule kvasir-root-${short} not found — run service-account bootstrap first"

  local content
  content="$(mac::_render_sudoers_fragment "nwalker" "$short")"

  kvasir::ssh_sudo "$host" "bash -c '
    cat > /tmp/kvasir.sudoers <<\"EOF\"
${content}
EOF
    chmod 0440 /tmp/kvasir.sudoers
    visudo -cf /tmp/kvasir.sudoers >/dev/null \
      || { echo \"visudo rejected fragment\" >&2; rm -f /tmp/kvasir.sudoers; exit 1; }
    if [[ -f \"${fragment_path}\" ]] && ! grep -q \"Managed by kvasir\" \"${fragment_path}\"; then
      cp \"${fragment_path}\" \"${fragment_path}.kvasir-bak.\$(date +%s)\"
    fi
    install -m 0440 -o root -g wheel /tmp/kvasir.sudoers \"${fragment_path}\"
    rm -f /tmp/kvasir.sudoers
  '"
  kvasir::log info "  ${fragment_path} installed"
}
```

- [ ] **Step 2: Commit**

```bash
git add lib/mac.sh
git commit -m "$(cat <<'EOF'
feat(mac): add write_sudoers step

Prechecks that IPA sudo rule kvasir-root-<short> exists, renders the
local sudoers fragment, validates via visudo -cf BEFORE installing,
backs up any pre-existing non-kvasir fragment at the same path, then
installs with 0440 root:wheel.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 14: Add `mac::enroll` orchestrator

**Files:**
- Modify: `lib/mac.sh`

- [ ] **Step 1: Append to `lib/mac.sh`**

```bash
# ---------- top-level orchestrator ----------

# Full macOS enrollment flow. Called by bin/enroll-host when uname=Darwin.
# Mirrors the Linux 9-step structure with a 10-step macOS variant.
# Args: <ssh-host> <fqdn> <short> <lan-ip>
mac::enroll() {
  local host="$1" fqdn="$2" short="$3" lan_ip="$4"

  kvasir::log info "[mac 1/10] probing target host..."
  local probe sw_vers detected_ip
  probe="$(mac::probe_target "$host")"
  IFS='|' read -r sw_vers detected_ip <<<"$probe"
  [[ -z "$lan_ip" ]] && lan_ip="$detected_ip"
  kvasir::log info "  macOS ${sw_vers}, LAN IP ${lan_ip}"

  # Optional pre-existing-state check
  local refresh_rc=0
  mac::_should_refresh "$host" "$fqdn" || refresh_rc=$?
  case "$refresh_rc" in
    0) kvasir::log info "  detected fully-enrolled state — refreshing" ;;
    1) kvasir::log info "  detected clean state — fresh install" ;;
    2)
      if [[ "${KVASIR_FORCE_REENROLL:-0}" == "1" ]]; then
        kvasir::log warn "  partial state detected, --force-reenroll set — proceeding"
      else
        kvasir::die "  partial enrollment state detected on ${host}; pass KVASIR_FORCE_REENROLL=1 to override"
      fi
      ;;
  esac

  kvasir::log info "[mac 2/10] minting host record + OTP..."
  ipa::admin_kinit_in_container
  local otp
  otp="$(ipa::host_register "$fqdn")"
  kvasir::log info "  host record OK (OTP minted, host key will be (re)issued in step 3)"

  kvasir::log info "[mac 3-5/10] minting + installing host keytab..."
  mac::install_host_keytab "$host" "$fqdn"

  kvasir::log info "[mac 4/10] staging /etc/krb5.conf..."
  mac::stage_krb5_conf "$host"

  kvasir::log info "[mac 6/10] staging FreeIPA CA cert..."
  mac::stage_ca_cert "$host"

  kvasir::log info "[mac 7/10] binding to LDAP..."
  mac::bind_ldap "$host"

  kvasir::log info "[mac 8/10] ensuring root service account + sudo rule in IPA..."
  ipa::service_account_ensure_root "$short" "$fqdn" "$lan_ip"

  kvasir::log info "[mac 9/10] writing local sudoers fragment..."
  mac::write_sudoers "$host" "$short"

  kvasir::log info "[mac 10/10] validating + saving to 1Password..."
  mac::validate_identity "$host" "$fqdn"

  op::create_item "FreeIPA Host ${short}" "${KVASIR_OP_VAULT}" \
    "username=host/${fqdn}" \
    "concealed:enrollment-otp=${otp}" \
    "url=https://${KVASIR_FREEIPA_FQDN}" \
    "fqdn=${fqdn}" \
    "lan-ip=${lan_ip}" \
    "os=darwin-${sw_vers}" \
    "kerberos=enabled" \
    "sudo-fragment-path=/etc/sudoers.d/kvasir-managed-${short}" \
    "enrolled-at=$(date -u +%FT%TZ)" \
    "uninstall-cmd=ssh ${host} 'sudo rm /Library/Preferences/OpenDirectory/Configurations/LDAPv3/${KVASIR_FREEIPA_FQDN}.plist; sudo dscl /Search -delete / CSPSearchPath /LDAPv3/${KVASIR_FREEIPA_FQDN}; sudo killall opendirectoryd; sudo rm /etc/sudoers.d/kvasir-managed-${short}'" \
    "notesPlain=Enrolled by kvasir on $(date -u +%FT%TZ). Local users (ravenhelm/nate) untouched as break-glass. Re-run kvasir enroll-host ${short} --apply to rotate keytab + regenerate sudoers."

  kvasir::log info "DONE — ${fqdn} enrolled in ${KVASIR_FREEIPA_REALM} (macOS)"
}
```

- [ ] **Step 2: Commit**

```bash
git add lib/mac.sh
git commit -m "$(cat <<'EOF'
feat(mac): add mac::enroll orchestrator

Top-level entry point. Sequences the 10 enrollment steps, runs
pre-existing-state detection, and writes the 1Password record at the
end with an uninstall-cmd field for break-glass.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 15: Add `mac::uninstall` rollback helper

**Files:**
- Modify: `lib/mac.sh`

- [ ] **Step 1: Append to `lib/mac.sh`**

```bash
# ---------- uninstall / rollback ----------

# Reverse the enrollment. Not yet exposed as a subcommand; call directly
# from a recovery shell: source lib/common.sh + lib/mac.sh, then
# mac::uninstall <host> <short>.
# Args: <ssh-host> <short-hostname>
mac::uninstall() {
  local host="$1" short="$2"
  local plist_path="/Library/Preferences/OpenDirectory/Configurations/LDAPv3/${KVASIR_FREEIPA_FQDN}.plist"

  if kvasir::is_dry_run; then
    kvasir::log info "DRY: would unbind LDAP, remove keytab principal, delete sudoers fragment on ${host}"
    return 0
  fi

  kvasir::ssh_sudo "$host" "bash -c '
    # Unbind LDAP
    dscl /Search -delete / CSPSearchPath \"/LDAPv3/${KVASIR_FREEIPA_FQDN}\" 2>/dev/null || true
    dscl /Search/Contacts -delete / CSPSearchPath \"/LDAPv3/${KVASIR_FREEIPA_FQDN}\" 2>/dev/null || true
    rm -f \"${plist_path}\"
    killall opendirectoryd 2>/dev/null || true

    # Remove host principal from keytab
    if [[ -f /etc/krb5.keytab ]]; then
      ktutil <<KTEOF
read_kt /etc/krb5.keytab
list
quit
KTEOF
      # ktutil interactive mode is awkward; safer to just remove and let next enroll reinstall
      rm -f /etc/krb5.keytab
    fi

    # Remove sudoers fragment
    rm -f /etc/sudoers.d/kvasir-managed-${short}

    # Restore most recent backups if any
    latest_krb5=\$(ls -t /etc/krb5.conf.kvasir-bak.* 2>/dev/null | head -1)
    [[ -n \"\$latest_krb5\" ]] && mv \"\$latest_krb5\" /etc/krb5.conf || true
  '"
  kvasir::log info "  uninstall complete; local users untouched"
}
```

- [ ] **Step 2: Commit**

```bash
git add lib/mac.sh
git commit -m "$(cat <<'EOF'
feat(mac): add uninstall helper for rollback

Reverses LDAP bind, removes /etc/krb5.keytab (next enroll reinstalls),
deletes kvasir sudoers fragment, restores most recent krb5.conf backup.
Local users untouched. Not yet a subcommand — sourced and called
manually during recovery.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 16: Wire Darwin dispatch into `bin/enroll-host`

**Files:**
- Modify: `bin/enroll-host` (around current lines 86-94 — the OS detection block)

- [ ] **Step 1: Read current state to confirm insertion point**

Run: `awk 'NR>=85 && NR<=95 {printf "%d: %s\n", NR, $0}' bin/enroll-host`
Expected output (verify before editing):
```
85: kvasir::log info "  target LAN IP: ${TARGET_IP}"
86:
87: # Detect OS family for service name + package manager
88: OS_ID="$(ssh "${SSH_HOST}" '. /etc/os-release && echo $ID')"
89: case "$OS_ID" in
```

- [ ] **Step 2: Edit `bin/enroll-host`**

Use Edit to replace:

```
# Detect OS family for service name + package manager
OS_ID="$(ssh "${SSH_HOST}" '. /etc/os-release && echo $ID')"
case "$OS_ID" in
  ubuntu|debian) PKG_INSTALL="apt-get install -y freeipa-client"; SSH_SVC="ssh.service" ;;
  rocky|rhel|centos|fedora|almalinux) PKG_INSTALL="dnf install -y freeipa-client"; SSH_SVC="sshd.service" ;;
  *) kvasir::die "unsupported OS_ID: ${OS_ID}" ;;
esac
kvasir::log info "  os: ${OS_ID}  ssh-service: ${SSH_SVC}"
```

with:

```
# Detect OS kernel. macOS hosts get the Darwin path (lib/mac.sh) and
# return before Linux-specific probing runs.
OS_KERNEL="$(ssh "${SSH_HOST}" 'uname -s')"
if [[ "$OS_KERNEL" == "Darwin" ]]; then
  # shellcheck source=../lib/mac.sh
  source "${KVASIR_DIR}/lib/mac.sh"
  kvasir::log info "  os: darwin (delegating to lib/mac.sh)"
  mac::enroll "${SSH_HOST}" "${FQDN}" "${SHORT}" "${TARGET_IP}"
  kvasir::is_dry_run && kvasir::log warn "this was a DRY-RUN; pass --apply to actually do it."
  exit 0
fi

# Linux from here on.
OS_ID="$(ssh "${SSH_HOST}" '. /etc/os-release && echo $ID')"
case "$OS_ID" in
  ubuntu|debian) PKG_INSTALL="apt-get install -y freeipa-client"; SSH_SVC="ssh.service" ;;
  rocky|rhel|centos|fedora|almalinux) PKG_INSTALL="dnf install -y freeipa-client"; SSH_SVC="sshd.service" ;;
  *) kvasir::die "unsupported OS_ID: ${OS_ID}" ;;
esac
kvasir::log info "  os: ${OS_ID}  ssh-service: ${SSH_SVC}"
```

- [ ] **Step 3: Sanity-check that bash still parses the file**

Run: `bash -n bin/enroll-host`
Expected: no output, exit 0.

- [ ] **Step 4: Dry-run against odin to exercise the new path**

Run: `KVASIR_LOG_LEVEL=debug bin/kvasir enroll-host odin 2>&1 | head -30`
Expected: log lines showing Darwin detection and `[mac 1/10]` ... `[mac 10/10]` step labels, ending with "DRY-RUN" warning. No actual mutations.

- [ ] **Step 5: Commit**

```bash
git add bin/enroll-host
git commit -m "$(cat <<'EOF'
feat(enroll-host): dispatch to lib/mac.sh on Darwin targets

Adds an early branch in bin/enroll-host: if `uname -s` on the target
returns Darwin, source lib/mac.sh and delegate to mac::enroll, then
exit. Linux flow is untouched. Verified with a dry-run against odin
shows the 10-step macOS labels.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 17: Integration test (gated)

**Files:**
- Create: `tests/mac-enroll-host-integration-test.sh`

- [ ] **Step 1: Create the integration test**

```bash
#!/usr/bin/env bash
# Integration test for macOS enrollment.
#
# Gated by KVASIR_INTEGRATION_TARGET. If unset, exits 0 (skipped).
# If set, runs dry-run + optional --apply + post-state validation +
# uninstall against that target.
#
# REQUIREMENTS for the target:
#   - SSH reachable
#   - macOS (uname -s = Darwin)
#   - SSH user has NOPASSWD sudo (or KVASIR_SUDO_PASSWORD_OP set)
#   - You can afford to reset its FreeIPA state
#
# Usage:
#   KVASIR_INTEGRATION_TARGET=odin bash tests/mac-enroll-host-integration-test.sh
#   KVASIR_INTEGRATION_TARGET=odin KVASIR_INTEGRATION_APPLY=1 bash tests/...
set -euo pipefail

if [[ -z "${KVASIR_INTEGRATION_TARGET:-}" ]]; then
  printf 'SKIP: set KVASIR_INTEGRATION_TARGET to run\n'
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${KVASIR_INTEGRATION_TARGET}"

printf '=== dry-run against %s ===\n' "$TARGET"
"${ROOT}/bin/kvasir" enroll-host "$TARGET" 2>&1 | tee /tmp/kvasir-int-dryrun.log
grep -q '\[mac 1/10\]' /tmp/kvasir-int-dryrun.log \
  || { printf 'FAIL: dry-run did not enter macOS path\n' >&2; exit 1; }
grep -q '\[mac 10/10\]' /tmp/kvasir-int-dryrun.log \
  || { printf 'FAIL: dry-run did not reach step 10\n' >&2; exit 1; }
printf 'PASS: dry-run exercises all 10 mac steps\n'

if [[ "${KVASIR_INTEGRATION_APPLY:-0}" != "1" ]]; then
  printf 'SKIP: set KVASIR_INTEGRATION_APPLY=1 to actually apply\n'
  exit 0
fi

printf '=== apply against %s ===\n' "$TARGET"
"${ROOT}/bin/kvasir" enroll-host "$TARGET" --apply 2>&1 | tee /tmp/kvasir-int-apply.log
grep -q 'DONE' /tmp/kvasir-int-apply.log \
  || { printf 'FAIL: apply did not complete\n' >&2; exit 1; }

printf '=== post-state validation ===\n'
ssh "$TARGET" 'id nwalker' >/dev/null \
  || { printf 'FAIL: id nwalker fails post-apply\n' >&2; exit 1; }
printf 'PASS: id nwalker resolves\n'

ssh "$TARGET" 'sudo klist -k /etc/krb5.keytab 2>/dev/null | grep -q host/' \
  || { printf 'FAIL: host principal missing from keytab\n' >&2; exit 1; }
printf 'PASS: host principal in keytab\n'

# sudo -n requires the test runner to be nwalker on the target — skip if not
if ssh "$TARGET" 'whoami' | grep -q nwalker; then
  ssh "$TARGET" 'sudo -n true' \
    || { printf 'FAIL: nwalker sudo -n true failed\n' >&2; exit 1; }
  printf 'PASS: nwalker has NOPASSWD sudo\n'
else
  printf 'SKIP: SSH user is not nwalker; cannot test sudo grant from this side\n'
fi

printf '=== uninstall + re-validate clean ===\n'
"${ROOT}/bin/kvasir" enroll-host "$TARGET" 2>&1 >/dev/null  # dry-run baseline
source "${ROOT}/lib/common.sh"
source "${ROOT}/lib/op.sh"
source "${ROOT}/lib/freeipa.sh"
source "${ROOT}/lib/mac.sh"
kvasir::load_env
KVASIR_DRY_RUN=0 mac::uninstall "$TARGET" "${TARGET%%.*}"

ssh "$TARGET" 'id nwalker' >/dev/null 2>&1 \
  && { printf 'FAIL: id nwalker still resolves after uninstall\n' >&2; exit 1; }
printf 'PASS: id nwalker fails post-uninstall (clean state)\n'

printf '\nAll integration checks passed.\n'
```

Make executable: `chmod +x tests/mac-enroll-host-integration-test.sh`

- [ ] **Step 2: Smoke-test the skip path**

Run: `bash tests/mac-enroll-host-integration-test.sh`
Expected: `SKIP: set KVASIR_INTEGRATION_TARGET to run`

- [ ] **Step 3: Commit**

```bash
git add tests/mac-enroll-host-integration-test.sh
git commit -m "$(cat <<'EOF'
test(mac): add gated integration test for enroll-host

Runs against a real macOS target when KVASIR_INTEGRATION_TARGET is set.
Three phases: dry-run (verifies all 10 mac steps execute), optional
--apply (gated by KVASIR_INTEGRATION_APPLY=1), and uninstall + clean-
state re-validation. Documented as "run manually on a Mac you can
afford to reset."

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 18: Update README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update the command table row for `enroll-host`**

In `README.md`, find the row:

```
| `kvasir enroll-host <target>`       | Joins a Linux host to the `RAVENHELM.DEV` FreeIPA realm. ...
```

Replace with:

```
| `kvasir enroll-host <target>`       | Joins a Linux **or macOS** host to the `RAVENHELM.DEV` FreeIPA realm. **Linux:** OTP-based `ipa-client-install`, sssd + mkhomedir, sudo via IPA HBAC at runtime. **macOS:** Apple Directory Services LDAPv3 bind (anonymous read), Heimdal Kerberos with host keytab from `ipa-getkeytab`, kvasir-managed `/etc/sudoers.d/` fragment rendered from `kvasir-root-<short>` IPA sudo rule. Existing local Mac users (ravenhelm/nate) untouched as break-glass. See [`docs/mac-enrollment-design.md`](docs/mac-enrollment-design.md). |
```

- [ ] **Step 2: Add a Mac-specific quickstart line**

In the Quickstart section, after the existing `kvasir enroll-host vakr --apply` example, add:

```bash
# Enroll a macOS host (auto-detected via uname=Darwin)
kvasir enroll-host odin --apply
```

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "$(cat <<'EOF'
docs(readme): document macOS support in enroll-host

Update the command table row to reflect Linux + macOS paths and how
they differ (sssd vs DS, runtime HBAC vs rendered fragment). Add a
macOS line to the quickstart.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Final verification

- [ ] **Run all unit tests:**

```bash
cd /Users/nate/src/platforms/ravenhelm/.kvasir-worktrees/mac-enrollment-design
bash tests/ipa-host-keytab-test.sh
bash tests/mac-render-test.sh
bash tests/mac-state-detection-test.sh
bash tests/mac-enroll-host-integration-test.sh   # should SKIP
```

Expected: all PASS lines, no FAIL, the integration test SKIPs.

- [ ] **Dry-run against odin and skoll:**

```bash
bin/kvasir enroll-host odin 2>&1 | tee /tmp/dryrun-odin.log
bin/kvasir enroll-host skoll-ts 2>&1 | tee /tmp/dryrun-skoll.log
```

Expected: both reach `[mac 10/10]` and end with the "DRY-RUN" warning. Review output for plausibility (correct FQDNs, IPs, no errors).

- [ ] **Push branch and open PR for review:**

```bash
git push -u origin feat/mac-enrollment-design
gh pr create --title "feat: macOS host enrollment via FreeIPA" --body "$(cat <<'EOF'
## Summary
- Extends `kvasir enroll-host` to support Apple Silicon macOS targets
- Apple-native Directory Services LDAPv3 bind to FreeIPA `cn=accounts`
- Heimdal Kerberos with host keytab from `ipa-getkeytab` in container
- Kvasir-managed sudoers fragment rendered from IPA sudo rule

## Spec
See `docs/mac-enrollment-design.md` for the full design.

## Test plan
- [ ] All unit tests pass (`bash tests/*.sh`)
- [ ] Dry-run against odin shows all 10 mac steps
- [ ] Dry-run against skoll-ts shows all 10 mac steps
- [ ] Integration test passes against skoll (apply phase)
- [ ] 24h observation on skoll with nwalker SSH + sudo working
- [ ] Apply to odin; integration test passes
- [ ] Lab-status memory updated to note nwalker now works on macOS

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **After PR merge — follow-up tasks (separate plan, not part of this one):**

  1. Migrate `/etc/sudoers.d/powermetrics-monitor` on odin and skoll from `ravenhelm`/`nate` to `nwalker`, remove "REMOVE on FreeIPA enrollment" comment
  2. Update `~/.claude/projects/.../memory/feedback_admin_tools_use_tailscale.md` to note nwalker now usable on Mac hosts
  3. Add `bin/uninstall-host-mac` subcommand wrapping `mac::uninstall` (currently call-by-source only)

---

## Self-Review Notes

- **Spec coverage:** All 10 design steps map to tasks (steps 2-3-5 = Task 1 + Task 9; steps 4 = Task 8; step 6 = Task 10; step 7 = Task 11; step 8 = Task 12; step 9 = Tasks 5 + 13; step 10 = Task 14 orchestrator).
- **Idempotency design** — covered: Task 6 detector, Task 8 backup-then-install, Task 11 dedup CSPSearchPath append, Task 13 backup + visudo validate.
- **Rollback design** — covered: Task 15.
- **Testing design** — covered: Tasks 1, 2, 3, 4, 5, 6 unit tests; Task 17 integration.
- **Rollout plan** — covered in Final verification (push + PR + follow-ups).
- **Type/name consistency** — verified: `mac::enroll`, `mac::_render_*`, `mac::stage_*` / `mac::install_*` / `mac::bind_*` / `mac::validate_*` / `mac::write_*` patterns consistent throughout.
- **No placeholders** — every step has exact code, exact commands, exact paths.
