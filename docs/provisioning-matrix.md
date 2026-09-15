# Kvasir provisioning and certificate matrix

## ADR-022 alignment

Kvasir is the enrollment executor (ADR-022 §6): it coordinates FreeIPA/Dogtag, the lab step-ca throwaway root, and SPIRE registration without holding CA keys or copying private keys through the operator laptop. Lab epoch material (`lab-throwaway-20260820`) is pinned and never promoted; join-token-only SPIRE paths are lab-bootstrap — agents install only with `--install-agent`.

Kvasir is the enrollment executor. It does not become a CA, IdP, MDM, or
secret vault. Every mutating command stays dry-run unless `--apply` is passed.
Certificates are a projection of an enrollment receipt: the CLI requests them
from the authority that already owns that class.

## Live lab authorities (2026-08-20)

Throwaway software root only. Production `askr` on NetHSM is a later genesis,
not a rename of this CA.

| Authority | Role | Where | Issues |
| --- | --- | --- | --- |
| step-ca | Root of trust | hrafngud `10.10.20.10:9000` | Intermediates; pinned trust bundle; internal host TLS profile `endpoint-tls` |
| FreeIPA Dogtag | People, hosts, SSH, IPA service users | `ipa.ravenhelm.dev` inside `freeipa` | User, host, and IPA service certs under the Dogtag intermediate |
| SPIRE | Workload mTLS | hrafngud `10.10.20.10:8081`, trust domain `ravenmask.net` (lab estate) | SVIDs; join tokens. Agents are **not** installed unless `--install-agent` |

Kvasir never handles a CA signing key and never copies a private key through
the operator laptop or a receipt.

## Principal classes

| Class | Identity plane | Certificate plane | Command |
| --- | --- | --- | --- |
| **user** | FreeIPA user + Zitadel OIDC + 1Password | Dogtag user/client cert; SSH pubkey or SSH cert via IPA | `kvasir enroll user` then `kvasir cert issue --class user` |
| **host** | FreeIPA host principal + keytab + SSSD | Dogtag host cert via certmonger/`ipa cert-request`; IPA CA bundle via `ipa-certupdate` | `kvasir enroll host` then `kvasir cert issue --class host` |
| **endpoint** | host identity plus Fleet custody plus Rig principal | step-ca `endpoint-tls` for private HTTPS; step-ca root bundle in the OS trust store | `kvasir enroll endpoint` |
| **service** | host-scoped IPA user `svc-<host>-root`, sudo, SSH key | Dogtag user/client cert on that IPA user — **not** a self-signed openssl leftover | `kvasir enroll service` then `kvasir cert issue --class service` |
| **workload** | SPIFFE ID under `ravenmask.net` | SPIRE SVID from the SPIRE intermediate | `kvasir enroll workload` |

Public-edge TLS (Cloudflare / public ACME) stays outside this CLI.

## Lifecycle

| Command | Mutates | Proof |
| --- | --- | --- |
| `kvasir enroll {user,host,endpoint,service,workload}` | Identity and trust material for that class | Receipt on `--apply` |
| `kvasir cert issue \| renew \| revoke \| verify` | Certificates only, routed by `--class` | Cert metadata in receipt; never the key |
| `kvasir cert bundle` | OS trust store / `/etc/ipa/ca.crt` consumers | Pinned SHA-256 of the step-ca root |
| `kvasir verify <id\|principal>` | none | Re-checks evidence; fail-closed if an authority is unreachable |
| `kvasir receipt get <id>` | none | Local receipt only (kvasir-api/Vór is the future central ledger) |

Hyphenated commands (`enroll-host`, `enroll-user`, `service-account`, …)
remain stable aliases.

## Fail-closed rules

1. Missing Rig principal, Fleet host ID, CA URL, or SPIRE server is a
   preflight failure, not a skipped step that still prints **verified**.
2. A self-signed or leftover openssl cert is not an approved profile.
3. SPIRE agent install is opt-in and names a host; minting a join token is
   the default workload apply shape.
4. `--apply` still refuses to print provisioner passwords, join tokens, or
   private keys. Those go to 1Password or remain on the target.
