# Kvasir Service Account Automation Stage

Document ID: RAVENHELM-KVASIR-SERVICE-ACCOUNT-AUTOMATION-001
Status: Draft
Scope: Near-term host automation access before Forseti, Varar, Cedar, and full JIT workflow are ready
Source of Truth: FreeIPA
Primary Services: Kvasir, FreeIPA, SSSD, OpenSSH, sudo, 1Password, Tailscale
Future Services: OpenBao, Forseti, Varar/Vor, Cedar/Havamal, Tyr

## Purpose

This document defines the current practical stage for Kvasir-managed automation
host access.

The immediate goal is to stop recurring manual sudo approval prompts for trusted
automation while keeping the design compatible with the longer-term Ravenhelm
identity workflow.

This stage does not implement full JIT privileged access. It creates and
verifies a host-scoped automation identity that can log in over SSH and run
non-interactive sudo only on the intended host.

## Design Boundary

This is a bridge, not the final privileged access architecture.

In scope:

- Create a host-scoped FreeIPA service account.
- Attach an SSH public key to that FreeIPA user as directory bootstrap state.
- Install the same SSH public key into the host-local service account
  `authorized_keys` file.
- Create a host-scoped FreeIPA sudo rule with passwordless sudo.
- Store bootstrap credential material in 1Password.
- Verify that SSH and `sudo -n` work without prompting.
- Use Tailscale ACLs or tags to constrain network reachability.

Out of scope for this stage:

- Forseti privileged access workflow.
- Varar/Vor signed grant issuance.
- Cedar/Havamal policy evaluation.
- OpenBao dynamic SSH certificate issuance.
- Tyr evidence-chain schema.
- Replacing FreeIPA as the identity source of truth.

## Current Account Model

For each enrolled Linux host, Kvasir manages one host-scoped root-capable
automation account.

Naming:

```text
FreeIPA user: svc-<host>-root
FreeIPA sudo rule: kvasir-root-<host>
1Password item: FreeIPA Root Host <host>
```

Example for `vakr`:

```text
FreeIPA user: svc-vakr-root
FreeIPA sudo rule: kvasir-root-vakr
1Password item: FreeIPA Root Host vakr
```

The account is host-scoped by policy. It is not a general shared root account.

## Credential Model

At this stage, Kvasir stores bootstrap credential material in 1Password.

The `FreeIPA Root Host <host>` item contains:

- username: `svc-<host>-root`
- private SSH key as a concealed field
- target FQDN
- service account name
- certificate fingerprint
- notes containing the public key, generated certificate, sudo rule, host, and
  LAN IP when known

The generated certificate is currently an X.509 client certificate attached to
the FreeIPA user. It is not yet an OpenSSH user certificate and should not be
treated as the final SSH certificate model.

The longer-term replacement is OpenBao-issued short-lived SSH certificates.

## Host Access Flow

Current flow:

```text
Automation runner
  -> reaches host over Tailscale or approved network path
  -> logs in as svc-<host>-root
  -> SSHD accepts the key from host-local authorized_keys
  -> SSSD/FreeIPA provides the Unix account and remains bootstrap/directory key state
  -> FreeIPA sudo rule grants NOPASSWD root on that host
  -> automation runs sudo -n commands
```

Kvasir must prove this flow works. Creating the account is not enough.

## Required Host SSH Configuration

The host must be FreeIPA enrolled. Kvasir keeps the public key attached to the
FreeIPA user as directory bootstrap state, but the preferred SSH auth surface is
the host-local `~svc-<host>-root/.ssh/authorized_keys` file.

The effective OpenSSH configuration may support the equivalent of:

```text
AuthorizedKeysCommand /usr/bin/sss_ssh_authorizedkeys
AuthorizedKeysCommandUser nobody
```

Distribution packages may install this through included snippets. Kvasir should
verify behavior rather than assume a specific file path, but this is no longer
the only SSH key source for automation.

The minimum behavioral proof is:

```bash
sss_ssh_authorizedkeys svc-<host>-root
```

This command should print at least one SSH public key on the target host.

The host-local behavioral proof is:

```bash
grep -Fxq "<service-public-key>" ~svc-<host>-root/.ssh/authorized_keys
```

## Required Sudo Configuration

Kvasir creates a FreeIPA sudo rule:

```text
kvasir-root-<host>
```

The rule must:

- include user `svc-<host>-root`
- include host `<host>.ravenhelm.dev`
- allow command category `all`
- allow run-as user category `all`
- allow run-as group category `all`
- include sudo option `!authenticate`

The minimum behavioral proof is:

```bash
ssh svc-<host>-root@<host> 'sudo -n true'
```

This must exit successfully with no password prompt.

## Kvasir Commands

### Ensure Account

Existing command:

```bash
kvasir service-account <host> --apply
```

Expected behavior:

1. Upsert FreeIPA user `svc-<host>-root`.
2. Ensure FreeIPA sudo rule `kvasir-root-<host>`.
3. If no 1Password item exists, generate the initial credential bundle.
4. Attach generated SSH public key to the FreeIPA user.
5. Attach generated certificate to the FreeIPA user.
6. Store credential metadata in `FreeIPA Root Host <host>`.

This command is idempotent. If the 1Password item already exists, Kvasir should
refresh the FreeIPA user and sudo rule without rotating credentials.

### Install Host Authorized Key

Required command:

```bash
kvasir install-service-account-key <host> --apply
```

Expected behavior:

1. Read the bootstrap private key from `FreeIPA Root Host <host>`.
2. Derive the matching public key.
3. Log in as `svc-<host>-root`.
4. Create `~svc-<host>-root/.ssh/authorized_keys` if needed.
5. Add the public key idempotently.

### Verify Account

Required new command:

```bash
kvasir verify-service-account <host>
```

This command is read-only against the target host and FreeIPA state.

Expected checks:

1. Resolve host short name and FQDN.
2. Derive service account name `svc-<host>-root`.
3. Confirm the matching 1Password item exists.
4. Confirm the target host is reachable over SSH.
5. On the target host, confirm the service account resolves:

   ```bash
   getent passwd svc-<host>-root
   ```

6. On the target host, confirm SSSD returns at least one SSH key:

   ```bash
   sss_ssh_authorizedkeys svc-<host>-root
   ```

7. Confirm host-local `authorized_keys` contains the service account key.

8. Confirm SSH login works as the service account:

   ```bash
   ssh svc-<host>-root@<host> 'id'
   ```

9. Confirm sudo works non-interactively:

   ```bash
   ssh svc-<host>-root@<host> 'sudo -n true'
   ```

10. Print a pass/fail table.

The command must not prompt for sudo. If a check would require a password prompt,
the verification fails.

## Verification Output

The command should emit a compact table:

```text
Host: vakr.ravenhelm.dev
Service account: svc-vakr-root

Check                              Result  Evidence
1Password item exists              PASS    FreeIPA Root Host vakr
Target SSH reachable               PASS    ssh vakr true
FreeIPA/SSSD user resolves         PASS    uid/gid returned
SSSD authorized keys resolves      PASS    1 key
Host authorized_keys contains key  PASS    ~svc-vakr-root/.ssh/authorized_keys
Service account SSH login          PASS    uid=...
Passwordless sudo                  PASS    sudo -n true
```

If a check fails, Kvasir should print the next action:

```text
SSSD authorized keys resolves      FAIL    0 keys
Action: rerun kvasir service-account vakr --apply, then verify sshd uses sss_ssh_authorizedkeys
```

## Failure Modes And Actions

| Failure | Likely Cause | Action |
| --- | --- | --- |
| `getent passwd svc-<host>-root` fails | Host is not FreeIPA/SSSD enrolled or SSSD is unhealthy | Re-run or repair `kvasir enroll-host <host> --apply` |
| `sss_ssh_authorizedkeys svc-<host>-root` prints no keys | SSH public key was not attached in FreeIPA or SSSD cannot read it | Re-run `kvasir service-account <host> --apply` and inspect FreeIPA user attributes |
| host `authorized_keys` does not contain the key | Host-local key install has not run or home creation failed | Run `kvasir install-service-account-key <host> --apply` |
| SSH login fails but keys resolve | Host-local `authorized_keys`, SSSD SSH lookup, or client key is wrong | Verify host-local `authorized_keys`, `AuthorizedKeysCommand` behavior, and 1Password private key material |
| `sudo -n true` fails | FreeIPA sudo rule missing, stale, not applied, or host not matched | Refresh service account and sudo rule, restart/refresh SSSD sudo cache |
| SSH works only by prompting | Automation is using the wrong identity or key | Ensure automation uses `svc-<host>-root` and the matching 1Password/OpenBao credential |
| Host unreachable | Network path or Tailscale ACL issue | Fix tailnet reachability before debugging identity |

## Security Notes

This stage intentionally grants strong host-local authority. Mitigations:

- Use one service account per host.
- Scope the sudo rule to one host.
- Require `sudo -n` verification so automation fails closed instead of prompting.
- Limit network reachability with Tailscale ACLs or host firewall policy.
- Store credential material in 1Password as bootstrap material only.
- Prefer OpenBao short-lived SSH certificates as the next hardening step.

Standing long-lived private keys remain a known weakness of this stage.

## Tailscale Role

Tailscale should constrain where automation can connect.

Recommended pattern:

```text
automation runner: tag:automation-runner
target hosts: tag:linux-host or tag:prod-host
```

ACLs should allow only the required SSH paths.

Tailscale does not replace FreeIPA or sudo policy. It only narrows the network
path and machine boundary.

## OpenBao Follow-On

OpenBao is the preferred next hardening step.

Target future flow:

```text
Automation runner
  -> authenticates to OpenBao
  -> receives short-lived SSH certificate for svc-<host>-root
  -> SSHD trusts OpenBao SSH CA
  -> service account logs in over SSH
  -> FreeIPA sudo rule allows sudo -n
```

Kvasir should eventually:

1. Configure host trust for the OpenBao SSH CA.
2. Request or wrap a short-lived SSH cert for `svc-<host>-root`.
3. Stop storing long-lived private keys as the normal automation path.
4. Keep 1Password material only for bootstrap or break-glass.

## Acceptance Criteria For This Stage

A host is ready for automation when all of these are true:

- `kvasir service-account <host> --apply` completes successfully.
- `FreeIPA Root Host <host>` exists in 1Password.
- `getent passwd svc-<host>-root` works on the target.
- `sss_ssh_authorizedkeys svc-<host>-root` returns at least one key on the target.
- `~svc-<host>-root/.ssh/authorized_keys` contains the service account public key.
- `ssh svc-<host>-root@<host> 'id'` succeeds.
- `ssh svc-<host>-root@<host> 'sudo -n true'` succeeds.
- Automation can run the required command without asking for human approval.
- Network access is constrained to approved automation runner to target host paths.

## What This Fixes

This stage fixes repeated human interruptions for already-approved host
automation by making the host access path explicit and testable.

It does not create a full privileged access platform. It creates a reliable,
auditable bridge that can later be replaced or hardened by OpenBao, Forseti,
Varar, Cedar/Havamal, and Tyr.
