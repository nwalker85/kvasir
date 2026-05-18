# Kvasir

> *In Norse myth, Kvasir was formed from the saliva of all gods — the wisest
> being, distilled from many sources. Fitting for a tool that combines
> FreeIPA, Zitadel, and 1Password into one onboarding workflow.*

Identity-onboarding automation for the Ravenhelm platform. One command per
workflow; minimal end-user input.

## What it does


| Command                             | Effect                                                                                                                                                                                                                                                                                                                                                                                                              |
| ----------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `kvasir enroll-host <target>`       | Joins a Linux host to the `RAVENHELM.DEV` FreeIPA realm. Drives the recipe in `[memory/freeipa-fleet-enrollment-recipe.md](../../../.claude/projects/-Users-nate-docs-personal-audio/memory/freeipa-fleet-enrollment-recipe.md)`: pre-creates the host record with an OTP, copies the CA cert, runs `ipa-client-install`, patches `default.conf`, enables sssd + mkhomedir, validates, ensures the host-scoped root service account + sudo rule, and stores the OTP in 1Password. |
| `kvasir service-account <target>`   | Ensures the host-scoped root service account exists in FreeIPA and creates the initial credential bundle + 1Password item if needed. |
| `kvasir install-service-account-key <target>` | Installs the service-account public key into host-local `~svc-<host>-root/.ssh/authorized_keys`. Use `--bootstrap-user` for first install when the service account cannot SSH yet. |
| `kvasir verify-service-account <target>` | Verifies the 1Password item, target SSH reachability, FreeIPA/SSSD user resolution, SSSD SSH keys, host-local `authorized_keys`, service-account SSH login, and `sudo -n true` without prompting. Use `--ssh-host` and `--probe-user` when the identity host name and network route differ. |
| `kvasir enroll-user <user> <email>` | Provisions a user in FreeIPA + Zitadel and stores credentials in 1Password (`FreeIPA <user>` item, ravenmask vault).                                                                                                                                                                                                                                                                                                |
| `kvasir add-ssh-key --fido2`        | Generates a resident FIDO2 ed25519-sk key on the YubiKey, registers it on the FreeIPA user via `ipa user-mod --addattr=ipasshpubkey`, and wires up `~/.ssh/config` with a `Match user` block.                                                                                                                                                                                                                       |


## Prerequisites

- `op` CLI signed in (1Password)
- `ssh` access to the FreeIPA services host (`hrafngud-ts-svc` by default, `hrafngud-svc` as fallback) — the `ipa` CLI runs inside the `freeipa` container via `docker exec`
- if the FreeIPA host does not allow plain Docker access for the SSH user, set `KVASIR_FREEIPA_DOCKER_SUDO_PASSWORD_OP` to a 1Password secret URI containing the host sudo password
- `/opt/homebrew/bin/ssh-keygen` for FIDO2 key generation (Apple's `/usr/bin/ssh-keygen` lacks FIDO2 support)
- `jq`, `curl`, `openssl` on $PATH

## Safety model

**Defaults to `--dry-run`.** Every script logs every mutation it would perform without doing it. Pass `--apply` to actually mutate. Idempotent where possible:

- `enroll-host` uses `host-mod` if the record exists, `host-add` if not
- `service-account` can be run independently to refresh the host-scoped root service account without repeating the host enrollment flow
- `enroll-user` skips creation if a user with the login name already exists
- `add-ssh-key` uses `--addattr` (additive), never replaces existing keys; reuses an existing local FIDO2 key if one is present at `~/.ssh/id_ed25519_sk_yubikey`
- `~/.ssh/config` edits are guarded with `# >>> kvasir Match ... >>>` markers

## Configuration

Defaults in `[etc/kvasir.env.example](etc/kvasir.env.example)`. Override by:

1. exporting env vars before running, or
2. creating `~/.config/kvasir/env` with overrides, or
3. setting `KVASIR_ENV_FILE=/path/to/env` before invoking

## Layout

```
kvasir/
├── bin/
│   ├── kvasir          # entrypoint dispatcher
│   ├── enroll-host
│   ├── service-account
│   ├── install-service-account-key
│   ├── verify-service-account
│   ├── enroll-user
│   └── add-ssh-key
├── lib/
│   ├── common.sh       # logging, dry-run, env, error trap
│   ├── op.sh           # 1Password helpers
│   ├── freeipa.sh      # ipa CLI via docker exec on FreeIPA host
│   └── zitadel.sh      # mgmt/v1 + v2 REST
├── etc/
│   └── kvasir.env.example
└── docs/
    └── runbook.md
```

## Quickstart

```bash
# Install on PATH
ln -sf "$PWD/bin/kvasir" /usr/local/bin/kvasir

# Dry-run a host enrollment
  kvasir enroll-host vakr

# Apply for real
kvasir enroll-host vakr --apply

# Refresh just the host-scoped root service account
kvasir service-account vakr --apply

# Install the service key into host-local authorized_keys
kvasir install-service-account-key vakr --apply

# Verify the service account can log in and run non-interactive sudo
kvasir verify-service-account vakr

# If the local SSH alias points at the wrong network path
kvasir install-service-account-key grani --ssh-host 100.106.47.41 --apply
kvasir verify-service-account grani --ssh-host 100.106.47.41

# Add a YubiKey-backed SSH key for the current user
kvasir add-ssh-key --fido2 --apply

# Provision a new identity
kvasir enroll-user jdoe jdoe@example.com --first Jane --last Doe --apply
```

## Background

The recipe being automated was developed and validated on `grani` 2026-04-26
(see `memory/freeipa-fleet-enrollment-recipe.md`). It works around the
`mod_auth_gssapi 1.6.3` S4U2Proxy bug
(`memory/freeipa-mod-auth-gssapi-s4u2proxy-bug.md`) by joining via the OTP /
`ipa-join` LDAP path instead of `--principal admin --password` (which routes
through the broken `/ipa/json` endpoint).
