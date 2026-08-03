# macOS host enrollment — postmortem (2026-05-25)

> First end-to-end attempt: enrolled `skoll` and `odin` into FreeIPA via
> `kvasir enroll-host`. Hit six distinct issues, fixed four in code on
> main, hit two hard architectural blockers that need a redesign. Code on
> main is **not end-to-end working on macOS** as of this writing — design
> + plan are good foundations but the LDAP-bind path needs a rethink.

Companion to [`mac-enrollment-design.md`](mac-enrollment-design.md) and
[`mac-enrollment-plan.md`](mac-enrollment-plan.md).

## What shipped (works)

The first 5 of 10 enrollment steps are end-to-end working on real macOS targets:

- ✅ Probe target (uname=Darwin, sw_vers, en0 IP)
- ✅ Mint host record + Kerberos principal (via FreeIPA container in "direct" mode — no OTP)
- ✅ Retrieve host keytab via `ipa-getkeytab` as admin
- ✅ Install keytab on target at `/etc/krb5.keytab` (0600 root:wheel)
- ✅ Stage `/etc/krb5.conf` with realm config
- ✅ Stage FreeIPA CA cert at `/etc/openldap/cacert.pem`

Plus FreeIPA server-side fixes that benefit the whole fleet (not just Mac enrollment):

- ✅ `ra_plugin = dogtag` added to `/etc/ipa/default.conf` — restores `Backend.ra`. Was blocking `ipa host-del` and any cert-touching command across the fleet, not just Mac enrollment.

## Issues encountered + resolutions

| # | Issue | Resolution | Status |
|---|---|---|---|
| 1 | FreeIPA `Backend.ra` not registered → `host_del` crashed with `AttributeError: ra`. Server-side bug; pre-dated this work, would have blocked any host re-enrollment fleet-wide. | Added `ra_plugin = dogtag` to `/etc/ipa/default.conf` + `pkill -HUP httpd` inside container. | ✅ fixed on hrafngud |
| 2 | `ipa host-add --password=<otp>` deliberately omits `krbPrincipalName` (designed for `ipa-client-install` consumption). Mac path can't consume OTPs because no `ipa-client-install` exists. | Added `mode=direct` to `ipa::host_register` — host-add without password creates the krb principal at add-time. Linux callers unchanged (default `mode=otp`). | ✅ fixed (kvasir commit `533d841`) |
| 3 | `klist -k <path>` is MIT syntax; macOS Heimdal `klist` rejects it (usage banner to stderr, empty stdout). kvasir validation died silently. | Switched validation paths to `ktutil --keytab=<path> list` (Heimdal-compatible). Updated `_should_refresh` to use `test -f /etc/krb5.keytab` as presence proxy (no sudo). | ✅ fixed (kvasir commit `a99eac4`) |
| 4 | `ipa.ravenhelm.dev` resolves to public Cloudflare IPs from inside the cluster — Mac path has no internal DNS override. Linux enroll-host stages `/etc/hosts`; macOS path didn't. | Manually patched `/etc/hosts` on odin to validate. **Not yet patched in kvasir** — see Outstanding Work. | ⚠️ workaround only |
| 5 | **SIP blocks direct plist writes** to `/Library/Preferences/OpenDirectory/Configurations/LDAPv3/`. Even root can't `mkdir` there. The design assumed "write plist directly + reload opendirectoryd" — incompatible with modern macOS. | The sanctioned interface is `dsconfigldap`. Not yet rewired in kvasir. | ❌ blocker |
| 6 | **macOS trust store changes require interactive user consent.** `sudo security add-trusted-cert -d -r trustRoot` fails non-interactively: "The authorization was denied since no user interaction was possible." Without CA trust, `dsconfigldap` errors `9006` and `ldapsearch` fails with `kSecTrustResultRecoverableTrustFailure`. | Apple's design — only paths around it are (a) interactive TouchID/password prompt at the device, or (b) install a configuration profile (`.mobileconfig`) via `profiles install`. | ❌ blocker |

## Why the design needs a redesign

The current design assumed three things that don't hold on modern macOS:

1. **"Write the plist directly to skip `dsconfigldap`'s GUI hooks."** SIP blocks this. There is no scripted way to create files under
   `/Library/Preferences/OpenDirectory/Configurations/` without going
   through `dsconfigldap` or an MDM-installed profile.
2. **"Anonymous LDAP bind for read."** This was framed as the design risk
   to validate — and it might still be fine ACI-wise — but the prerequisite
   (TLS trust) requires a CA cert in the system keychain, which itself
   requires interactive consent.
3. **DNS resolution.** The design didn't mention `/etc/hosts` staging because Linux enroll-host's behavior wasn't carried forward. Public DNS for `ipa.ravenhelm.dev` points at Cloudflare; internal clients need an override.

## Suggested next architecture: configuration-profile-based binding

macOS provides a sanctioned non-interactive path for both LDAP binding and trust-store changes: a configuration profile (`.mobileconfig` XML file) installed via `profiles install -path <profile.mobileconfig>`. This is the Apple-approved MDM pattern but works without an MDM server.

A single profile can contain:

- The LDAPv3 configuration (server, search base, mapping templates, bind credentials) — installed directly to OpenDirectory bypassing SIP
- The CA certificate with trust settings (`com.apple.security.pem` + `com.apple.security.root` payloads) — installs to the system keychain with trust **without user consent prompts** when installed via `profiles install`
- DNS overrides (less reliable; `/etc/hosts` staging is still the right move)

This collapses issues 4, 5, and 6 into a single mechanism. The kvasir flow becomes:

```
mac::bind_ldap() {
  render profile XML (server FQDN, search base, bind DN/creds, embedded CA cert)
  scp to target
  ssh_sudo profiles install -path <profile>
  verify with: dscl /Search -read / CSPSearchPath | grep LDAPv3
}
```

`profiles install` runs non-interactively when invoked with sudo. The system trust store and OpenDirectory both get updated through Apple's sanctioned paths.

## Outstanding work

A redesign should produce:

1. **New `lib/mac.sh::bind_ldap` implementation** using `profiles install` with a rendered `.mobileconfig` XML payload.
2. **New `lib/mac.sh::_render_mobileconfig` renderer** producing the XML (embedding the CA cert, LDAPv3 config with RFC2307 mappings, search policy entries).
3. **New step in `mac::enroll`:** stage `/etc/hosts` with `${KVASIR_FREEIPA_LAN_IP} ${KVASIR_FREEIPA_FQDN}` — match Linux enroll-host's behavior.
4. **Provision a low-priv readonly bind DN in FreeIPA** (1Password item `FreeIPA LDAP Bind Readonly`) — used by the mobileconfig for LDAP queries. Anonymous bind may work for some attrs but bind-DN is more robust against ACI tightening.
5. **Reuse what's working:** keep the existing `mac::install_host_keytab`, `mac::stage_krb5_conf`, `mac::stage_ca_cert`, `mac::write_sudoers`, `mac::validate_identity`, `mac::probe_target`. None of these need to change.
6. **Update the design doc** to reflect the mobileconfig approach. Section "Approaches considered" should add a "D — Configuration profile (chosen)" entry.
7. **Update the plan** to add: profile renderer task, `profiles install` step task, `/etc/hosts` staging task. Remove: direct plist write, dscl CSPSearchPath append, killall opendirectoryd (the profile install handles all of these).

Estimated scope: ~6-8 hours of focused work plus testing on at least one real macOS target.

## What was tested

- skoll (M1 Pro, macOS 26.4.1): direct-mode host-add → keytab install → step 6 SIP block
- odin (M4 Pro, macOS 26.2): direct-mode host-add → keytab install → krb5.conf staged → CA cert staged → step 6 SIP block (TLS trust + plist write both fail)
- ravenmask laptop (M5, macOS): never enrolled — testing client only

## Cleanup performed

After hitting issue 6 on odin:

- Deleted FreeIPA host records: `skoll.ravenhelm.dev`, `odin.ravenhelm.dev`
- Removed `/etc/krb5.keytab`, `/etc/krb5.conf`, `/etc/openldap/cacert.pem` from both targets
- Removed `/etc/sudoers.d/temp-{nate,ravenhelm}-enroll` (the interim NOPASSWD grants we used)
- Removed `10.10.20.10 ipa.ravenhelm.dev` line from `/etc/hosts` on odin

**Not cleaned up:** the FreeIPA server-side `ra_plugin = dogtag` fix in `/etc/ipa/default.conf` on hrafngud's container. Keep it — it's a legitimate server fix that benefits all hosts, not specific to this attempt.

## What's kept in main

- `docs/mac-enrollment-design.md` — original spec (will need amendment)
- `docs/mac-enrollment-plan.md` — original plan (will need amendment)
- `lib/mac.sh` — most of it (renderers + step functions are correct; bind_ldap needs rewrite)
- `lib/freeipa.sh` — the `ipa::host_register mode=direct` enhancement is good
- `bin/enroll-host` — the Darwin dispatch is correct
- Tests — all green; the test that exercises bind_ldap will need updating with the new approach

## References

- macOS configuration profile schema for LDAP: [Apple's "Profile Manager" guide](https://developer.apple.com/business/documentation/Configuration-Profile-Reference.pdf) (search "LDAP")
- `profiles(1)` man page — the install/list/remove CLI
- `dsconfigldap(8)` man page — for understanding what Apple supports as the sanctioned scripted binding path
- FreeIPA host-del internal-error root cause (`Backend.ra` missing) — fixed in this session, separately documented in `feedback_freeipa_ra_plugin.md` (TODO add this memory file)
