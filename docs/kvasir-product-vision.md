# Kvasir Product Vision — Enrollment and Trust Control Plane

**Status:** Draft  
**Date:** 2026-07-23  
**Product:** Kvasir

## The product in one sentence

Kvasir makes a person, endpoint, or workload **known, trusted, admitted, and
continuously healthy** across Ravenhelm without making any one integration the
source of truth for everything.

Kvasir is the lifecycle executor for the identity-and-trust graph. It turns an
approved intent into a bounded sequence of evidence-bearing actions: create or
verify identity, establish device or workload identity, install the right trust
roots, obtain short-lived credentials, prove posture, apply admission policy,
and record what happened.

## Why this exists

Ravenhelm already has strong systems with distinct authority:

- Rig resolves canonical principals, tenancy, and policy relationships.
- FreeIPA owns the Unix and Kerberos realm.
- Zitadel owns human and application OIDC identity.
- FleetDM owns endpoint inventory, posture, and MDM delivery.
- A private PKI issues internal TLS and SSH credentials.
- SPIRE issues runtime workload identities for service-to-service mTLS.
- OPNsense enforces network admission and segmentation.
- 1Password holds bootstrap and break-glass material.

The missing product is the **joined-up lifecycle**. Today, a host can be in
FreeIPA but absent from Fleet, have a certificate but no recorded owner, or be
healthy in Fleet yet retain network access after its trust state has drifted.
Manual cross-system work also leaves no durable answer to: “Who admitted this
thing, under which policy, and is that decision still valid?”

Kvasir closes that gap. It does not replace these systems; it binds their
outcomes into one controlled, observable enrollment lifecycle.

## Product promise

For every managed principal, Kvasir will make four things answerable:

1. **Identity:** What is this person, endpoint, or workload, and which Rig
   principal owns it?
2. **Trust:** Which roots, certificates, workload identities, and credentials
   are active, when do they expire, and how are they renewed or revoked?
3. **Admission:** Which policy allowed it onto which network or service plane,
   and what evidence supported that decision?
4. **Receipt:** What actions occurred, by whom or which automation, with what
   non-secret evidence, and what must happen next?

The operator experience should be small and decisive: submit an enrollment,
inspect its plan in dry-run form, apply it deliberately, and receive a receipt
whose lifecycle remains queryable afterward.

## Authority model

Kvasir coordinates authority; it never absorbs it.

| System | Remains authoritative for | Kvasir's role |
| --- | --- | --- |
| Rig | Canonical principals, tenant and organization context, relationship and policy decisions | Resolve the target principal; request and record governed enrollment decisions |
| FreeIPA | Unix accounts, host principals, Kerberos, LDAP, IPA-managed SSH and sudo policy | Create or verify realm identity and collect non-secret evidence |
| Zitadel | Human and application OIDC identities | Provision or validate OIDC identity where the lifecycle requires it |
| FleetDM | Endpoint inventory, posture, MDM enrollment, configuration delivery | Verify endpoint custody and use MDM as a delivery channel for managed trust |
| Private CA (initially Smallstep step-ca) | Internal X.509 issuance, renewal and revocation | Request certificates under approved profiles; never hold CA signing keys |
| SPIRE | Workload SVIDs, SPIFFE registration and runtime mTLS | Register approved workloads and verify SVID delivery; never become a second workload CA |
| OPNsense | Network rules, aliases, VLAN and gateway enforcement | Ask for bounded policy application and record the resulting admission evidence |
| 1Password | Bootstrap, recovery, and human-held secret custody | Resolve narrowly scoped bootstrap material; never place it in receipts or logs |

The boundary is intentional:

- Rig is the graph and policy authority; Kvasir is its operational executor.
- Kvasir is not a CA, IdP, MDM, network controller, secret vault, or universal
  admin console.
- Kvasir never persists private keys, password values, recovery codes, or
  bearer credentials in its receipts.
- An enrollment may fail closed or stop in a recoverable state, but it must not
  silently leave an unrecorded partially trusted object behind.

## End-state lifecycle

Every enrollee has a single lifecycle record with a stable ID and append-only
step receipts. The state is a projection of evidence, not a hand-maintained
label.

| State | Meaning |
| --- | --- |
| Discovered | Observed by an inventory or request source but not yet evaluated |
| Candidate | A request has a resolved target and proposed Rig principal |
| Verified | Required identity, ownership, and posture preconditions have evidence |
| Enrolled | The applicable identity-plane changes succeeded |
| Trusted | Required root bundles and credential profiles are present and valid |
| Admitted | Network or service admission policy is active |
| Degraded | Still admitted, but a renewal, posture, or reachability obligation is failing |
| Quarantined | Explicitly denied or isolated by policy |
| Revoked | Credentials and admission have been withdrawn |
| Retired | Historical record retained; no active identity or admission remains |

An object cannot move to **Admitted** based only on an operator assertion. It
must have the policy-required evidence for its class. Conversely, a certificate
expiry should not be discovered only when a service breaks: it should transition
the lifecycle to **Degraded** early enough for a defined remediation policy.

## Product surfaces

Kvasir begins with a CLI because enrollment is privileged, operational work.
It grows into a small control-plane API and query surface without discarding the
auditable command path.

### Operator commands

- `kvasir enroll endpoint <target>`
- `kvasir enroll workload <workload>`
- `kvasir enroll user <user> <email>`
- `kvasir verify <enrollment-id | principal>`
- `kvasir renew <enrollment-id | principal>`
- `kvasir revoke <enrollment-id | principal>`
- `kvasir receipt get <enrollment-id>`

All mutating commands retain the current dry-run-first model. Their plan must
declare the exact systems to be touched, the policy decision being relied upon,
and the effects that will be intentionally deferred.

### Enrollment receipt

The receipt is the durable product primitive. It includes:

- enrollment ID, target, class, and resolved Rig principal reference;
- policy version or decision reference;
- integration steps, timestamps, outcomes, and non-secret evidence references;
- installed trust-bundle digest and credential metadata such as subject, SANs,
  profile, and expiry — never private material;
- current lifecycle state, owner, remediation deadline, and next action.

Receipts are immutable events. Current status is a derived view so an
integration can be rechecked without overwriting the historical result.

### Policy and connector contracts

Kvasir needs two durable contracts:

1. **Enrollment policy contract:** object class, owner, required evidence,
   permitted credential profiles, admission scope, and revoke/renew behavior.
2. **Connector contract:** preflight, plan, apply, verify, compensate where
   safe, and evidence. A connector may be unavailable, but it may not invent
   success.

This makes providers replaceable without making identity or audit meaning
replaceable.

## Trust architecture

“Every host and service has SSL” means every applicable listener and client has
an identity appropriate to its plane; it does not mean minting unmanaged leaf
certificates for every process.

| Plane | Identity and certificate path |
| --- | --- |
| Public edge | Cloudflare or public ACME certificates, outside Kvasir's private PKI issuance path |
| Internal host and service TLS | Smallstep step-ca profiles and automated renewal; Kvasir enrolls trust and records the profile |
| FreeIPA realm | FreeIPA Dogtag and certmonger remain the IPA realm certificate path |
| Workload-to-workload mTLS | SPIRE SPIFFE/SVID identity and workload registration |
| SSH | Short-lived SSH certificates where the designated CA supports them, with FreeIPA policy retained for Unix access |
| Endpoint trust distribution | FleetDM/MDM configuration delivery plus direct bootstrap verification when MDM is unavailable |

Kvasir knows which path applies to an object. It does not collapse these trust
domains into one CA or one generic certificate.

## Core journeys

### Managed endpoint

An operator requests enrollment for a laptop, server, or appliance. Kvasir
resolves its Rig endpoint principal, proves it is the intended target, confirms
Fleet custody, establishes the appropriate FreeIPA host identity, installs the
private trust bundle, obtains the approved host credential where applicable,
verifies it, and writes an enrollment receipt. Network admission follows only
the policy-defined decision point.

### Service workload

A service owner declares a workload and its service dependencies. Kvasir binds
the workload to its Rig principal, registers the SPIFFE identity and approved
selectors, verifies the service can obtain an SVID, and records its allowed
mTLS peers and renewal health. Deployment remains the workload platform's job.

### Renewal, degradation, and revocation

Kvasir watches receipt obligations: certificate expiry, trust-bundle version,
Fleet posture, and identity changes. It renews only through the owning system.
If policy requires it, a failed renewal or loss of endpoint posture moves the
object through **Degraded** to **Quarantined** rather than leaving a silent,
long-lived exception.

### Emergency recovery

Break-glass remains a separately governed path. Kvasir can record that a
recovery occurred and open a reconciliation obligation; it must not make
break-glass access invisible or turn emergency material into routine automation.

## Security and operating principles

- **Least-privilege connectors:** each external integration uses its own
  constrained machine identity and scopes.
- **Short-lived credentials:** certificate and workload identity renewal is the
  normal operation, not a periodic manual project.
- **Attested bootstrap:** enrollment verifies target identity before placing
  trust material or credentials.
- **No secret receipts:** no PEM private keys, passwords, access tokens, or
  1Password fields are logged or stored.
- **Safe retries:** steps are idempotent or explicitly require an operator
  decision; a retry cannot silently rotate an identity beyond policy.
- **Human gates for blast radius:** broad network policy changes, trust-root
  rotation, and irreversible revocation require the configured approval path.
- **Observable failure:** a failed preflight or connector must produce a
  receipt with evidence and a safe next action.

## Success measures

The end state is successful when Ravenhelm can measure, rather than estimate:

- 100% of managed endpoints have an owner, a current enrollment receipt, and a
  verified trust-bundle version.
- 100% of internal services with an exposed TLS listener have a named
  certificate profile and renewal signal.
- 100% of workload-to-workload mTLS paths are declared through SPIFFE policy,
  not manually copied certificates.
- A standard endpoint enrollment completes in under ten minutes after
  prerequisites are healthy, with no secret copied through chat or a terminal.
- Certificate and posture failures are detected before expiry or loss of
  admission, with owner and remediation deadline attached.
- An audit query can explain a device or workload's current access state from
  receipt evidence alone.

## Product roadmap

| Stage | Outcome |
| --- | --- |
| 0 — stabilize | Preserve the existing host, user, and service-account CLI; standardize dry-run, evidence, and receipt conventions |
| 1 — endpoint MVP | Deliver deterministic endpoint enrollment with Rig reference, FreeIPA, Fleet, trust-bundle, private-CA verification, and local receipts |
| 2 — lifecycle health | Central receipt projection, renewal checks, expiry and posture degradation, operator query surface |
| 3 — workload trust | SPIRE registration, SVID verification, service mTLS policy and workload receipts |
| 4 — governed admission | Rig policy decisions drive bounded OPNsense and service-plane admission with approval gates |
| 5 — product experience | API, SDK, delegated workflows, dashboards, and cross-tenant policy reporting |

## Non-goals

- Replacing Rig as the canonical identity or policy graph.
- Replacing FreeIPA, Zitadel, FleetDM, step-ca, SPIRE, OPNsense, or 1Password.
- Centralizing private keys or issuing certificates directly from Kvasir.
- Automatically changing broad firewall policy without an approved policy
  contract and a tested rollback path.
- Treating every object class as equivalent. A laptop, FreeIPA host, public
  edge service, and Kubernetes workload have different trust requirements.

## Decisions that must stay explicit

The vision deliberately leaves several choices visible rather than burying them
in scripts:

1. The private CA is a platform decision. The working default is Smallstep
   step-ca for internal host and service certificates, while FreeIPA Dogtag and
   SPIRE keep their distinct scopes.
2. Rig defines policy and principal semantics before Kvasir mutates downstream
   systems. Kvasir needs a stable versioned policy decision contract.
3. OPNsense becomes an automated connector only after endpoint ownership,
   posture signals, alias/rule scope, and rollback rules are proven.
4. Central receipt storage must be selected before Kvasir becomes a
   multi-operator service. The CLI-local receipt is an MVP bridge, not the
   final audit system.

