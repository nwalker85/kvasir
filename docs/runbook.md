# Kvasir runbook

## Before you start

```bash
# 1. Verify 1Password CLI is signed in
op vault list   # should show ravenmask

# 2. Verify SSH access to the FreeIPA host
ssh hrafngud-svc "docker ps --filter name=freeipa --format '{{.Names}} {{.Status}}'"

# If that Docker check needs sudo on your host, set:
# export KVASIR_FREEIPA_DOCKER_SUDO_PASSWORD_OP="op://vault/item/password"

# 3. Optionally put kvasir on $PATH
ln -sf ~/src/platforms/ravenhelm/kvasir/bin/kvasir ~/.local/bin/kvasir
```

## Onboarding a new Linux host

```bash
# Dry-run first — shows every command without running it
kvasir enroll-host vakr

# When the dry-run looks right, apply
kvasir enroll-host vakr --apply
```

If the target's SSH alias doesn't match its short hostname (e.g. you have
`Host my-laptop  HostName 10.0.0.5  User ravenhelm` but want the FreeIPA
record to be `laptop.ravenhelm.dev`), pass the FQDN explicitly via
`--ip <lan>` and edit the SSH alias in `bin/enroll-host` if needed.

### What it does (9 steps, all logged)

1. Probes the target via SSH — gets OS family + LAN IP
2. `kinit admin` inside the freeipa container, mints a hex OTP, and
   `host-add` (or `host-mod`) the new host with that OTP
3. Stages `/etc/hosts` on the target (adds `ipa.ravenhelm.dev` and FQDN, removes the stock `127.0.1.1 short` line)
4. Installs `freeipa-client` package, copies CA cert from the container
5. Runs `ipa-client-install --password=$OTP --ca-cert-file=...` (OTP path bypasses the broken `/ipa/json` endpoint)
6. Appends `delegate = True` to `/etc/ipa/default.conf`, enables sssd, restarts ssh service, enables PAM mkhomedir
7. Validates: `id nwalker`, `sss_ssh_authorizedkeys nwalker`
8. Ensures the host-scoped root service account exists, adds an SSH key + certificate artifact when needed, and grants `NOPASSWD` root via a FreeIPA sudo rule
9. Saves the OTP + enrollment metadata as a 1Password item: `FreeIPA Host <short>` in the ravenmask vault

If you only need to refresh the service-account side later, use:

```bash
kvasir service-account vakr --apply
```

Install the service account key into host-local `authorized_keys`:

```bash
kvasir install-service-account-key vakr --apply
```

If the service account cannot SSH yet, use an existing sudo-capable bootstrap
login for the first host-local key install:

```bash
kvasir install-service-account-key vakr --bootstrap-user nwalker --apply
```

Then prove the automation path before using it:

```bash
kvasir verify-service-account vakr
```

The verifier is read-only. It checks the `FreeIPA Root Host <short>` 1Password
item, SSH reachability, `getent passwd svc-<host>-root`,
`sss_ssh_authorizedkeys svc-<host>-root`, host-local `authorized_keys`,
service-account SSH login with the stored bootstrap key, and `sudo -n true`.

If the host identity and SSH route differ, keep the target as the identity host
and override only the network path:

```bash
kvasir install-service-account-key grani --ssh-host 100.106.47.41 --apply
kvasir verify-service-account grani --ssh-host 100.106.47.41
```

### Common issues

- **`ssh ... permission denied`** — kvasir uses `sudo` non-interactively on the target. The target user needs passwordless sudo (or you need an interactive shell).
- **`/etc/ipa/ca.crt: No such file or directory`** — happens if a previous failed `ipa-client-install` rolled back. Re-run `kvasir enroll-host <host> --apply`; step 4 re-stages the cert.
- **`host record exists but enrollment fails`** — the OTP is single-use. Re-running rotates it via `host-mod --password=<new-otp>`.
- **`verify-service-account` shows `0 keys`** — re-run `kvasir service-account <host> --apply`, then verify sshd is using SSSD authorized-key lookup.
- **`verify-service-account` shows missing host `authorized_keys`** — run `kvasir install-service-account-key <host> --apply` or pass `--ssh-host` if the route differs from the host identity.
- **`verify-service-account` shows `sudo -n true` failed** — refresh the host sudo rule with `kvasir service-account <host> --apply`, then clear/restart the target SSSD sudo cache.

## Certificates and service identity

Identity join (`enroll-host`, `enroll-user`, `service-account`) does **not**
issue TLS or SVIDs. Use the cert/workload commands, which stay dry-run
unless `--apply` is passed.

```bash
# People / IPA service users / IPA hosts → Dogtag
kvasir cert issue --class user nwalker
kvasir cert issue --class service svc-grani-root --csr ./svc.csr
kvasir cert issue --class host grani.ravenhelm.dev --csr ./host.csr

# Trust bundle + internal host TLS → step-ca (lab throwaway root, not askr)
export KVASIR_STEPCA_FINGERPRINT='<sha256 of the live roots.pem>'
kvasir cert bundle
kvasir enroll endpoint grani \
  --rig-principal rig://endpoints/grani \
  --fleet-host-id 12

# Workload mTLS → SPIRE (no agent install unless you opt in)
kvasir enroll workload audio-app/frigate-recognizer
kvasir cert issue --class workload audio-app/frigate-recognizer
```

`--apply` for Dogtag requires a CSR generated on the subject. Kvasir will
not mint a self-signed leftover or copy a private key. SPIRE join tokens
are never printed. See [`provisioning-matrix.md`](provisioning-matrix.md).

## Provisioning a new user

```bash
kvasir enroll-user jdoe jdoe@example.com --first Jane --last Doe --apply
```

This creates the user in FreeIPA + Zitadel and stores their temp password
at `op://ravenmask/FreeIPA jdoe`. After they log in once and change their
password, they should run:

```bash
kvasir add-ssh-key --fido2 --apply
```

…to bind a YubiKey FIDO2 resident SSH key.

## Adding a YubiKey-backed SSH key for the current user

```bash
# Touch your YubiKey fingerprint when prompted
kvasir add-ssh-key --fido2 --apply
```

What this does:
- Generates a resident `ed25519-sk` key on the YubiKey (`-O verify-required`,
  `-O application=ssh:ravenhelm`) using brew openssh's internal sk-helper
- Stores the SSH wrapper at `~/.ssh/id_ed25519_sk_yubikey`
- Pushes the pubkey to your FreeIPA user via `ipa user-mod --addattr`
- Adds a `Match user $USER` block to `~/.ssh/config` (with kvasir markers)
  that uses `IdentityAgent none`, the new SK key, and `IdentitiesOnly yes` —
  bypasses the 1Password agent (which has no FIDO2 support)

Test with:

```bash
ssh nwalker@grani 'id nwalker'
# fingerprint UV prompt, then output:
# uid=1330800011(nwalker) gid=1330800011(nwalker) groups=...
```

## Importing an existing pubkey instead

```bash
kvasir add-ssh-key --pubkey ~/.ssh/some_existing_key.pub --user nwalker --apply
```

## Rolling back a host enrollment

Kvasir doesn't have a `decommission` command yet. Manual:

```bash
ssh hrafngud "docker exec freeipa kinit admin < /tmp/admin.pw && \
              docker exec freeipa ipa host-del <fqdn>"
ssh <target> "sudo ipa-client-install --uninstall --unattended"
op item delete "FreeIPA Host <short>" --vault ravenmask --archive
```

## Configuration overrides

Either:
1. Export env vars before running (e.g. `KVASIR_FREEIPA_HOST=newhost kvasir ...`)
2. Create `~/.config/kvasir/env` — kvasir loads it before defaults
3. Pass `KVASIR_ENV_FILE=/path` to point at a specific file

See [`../etc/kvasir.env.example`](../etc/kvasir.env.example) for the full
list of overrideable settings.
