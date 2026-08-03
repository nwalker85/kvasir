# Kvasir MVP PRD — Verified Endpoint Enrollment

**Status:** Draft  
**Date:** 2026-07-23  
**Product:** Kvasir  
**Milestone:** Stage 1 of the Kvasir product vision

## Decision summary

The MVP adds one first-class workflow:

> `kvasir enroll endpoint <target>` creates a deterministic, dry-run-first
> enrollment plan for one managed macOS or Linux endpoint; on apply it verifies
> identity, joins or validates the FreeIPA host identity, confirms FleetDM
> custody, installs and verifies the approved private trust bundle, obtains and
> validates an approved internal host TLS credential, and writes a non-secret
> receipt tied to a Rig endpoint principal.

The command succeeds only when it can prove the policy-required outcome. It
does not automatically change OPNsense admission rules in this milestone.

## Problem

Current Kvasir host enrollment is valuable but fragmentary. It can establish
FreeIPA identity and host-local service-account access, yet it has no durable
binding to:

- the endpoint's canonical Rig principal and owner;
- FleetDM custody and posture;
- the internal trust-bundle version;
- a private TLS certificate profile and expiry;
- a receipt describing the current state and evidence.

An operator must therefore assemble multiple systems manually and infer whether
the result is fit for network or service admission. That is slow, difficult to
audit, and unsafe to automate later.

## Existing foundation

This MVP extends rather than replaces the current repository:

- `bin/kvasir` dispatches dry-run-first commands for host, user, SSH-key, and
  service-account workflows.
- `bin/enroll-host` supports Linux FreeIPA enrollment and a macOS Directory
  Services plus Heimdal Kerberos path.
- `lib/freeipa.sh`, `lib/zitadel.sh`, `lib/op.sh`, and `lib/mac.sh`
  establish the shell-library and safety conventions.
- Existing shell tests cover renderers, FreeIPA operations, service-account
  installation, and macOS state detection.

The MVP must preserve the existing `enroll-host` command and its break-glass
behavior. `enroll endpoint` is a higher-level orchestrator that calls
well-defined existing functionality; it is not a rewrite.

## Users

| User | Need |
| --- | --- |
| Platform operator | Enroll a laptop or server once, know exactly what will change, and get proof of the outcome |
| Endpoint owner | Have a clear owner binding and safe remediation when device trust drifts |
| Security or network operator | Determine whether an endpoint has the evidence required for admission without inspecting five systems |
| Service owner | Consume a trusted endpoint prerequisite before later workload mTLS work |

## Goals

1. Make a macOS or Linux endpoint's identity, trust, and custody state
   observable in one receipt.
2. Keep the CLI dry-run-first and idempotent.
3. Require a resolved Rig endpoint principal before any mutation.
4. Verify the endpoint is visible and healthy enough in FleetDM before calling
   the outcome **verified**.
5. Install and fingerprint a versioned internal trust bundle.
6. Obtain and validate a private host TLS certificate using an approved CA
   profile, without Kvasir handling a CA signing key or retaining private
   material.
7. Leave a safe, machine-readable failure record when an operation stops.

## Non-goals

- Deploying or selecting the private CA infrastructure. The working integration
  target is Smallstep step-ca; its production deployment and root/intermediate
  governance are prerequisites, not deliverables of this PRD.
- Replacing FleetDM enrollment or MDM configuration delivery.
- Creating a central Kvasir API, database, or dashboard.
- Workload SPIRE registration, Kubernetes identity, or service-to-service mTLS.
- Automatic OPNsense rule or alias mutation.
- User lifecycle changes, Zitadel provisioning changes, or a new secret vault.
- Issuing public certificates.

## Preconditions

The implementation can be complete only when these environment capabilities
exist. The CLI must report a missing prerequisite as a clear preflight failure;
it must not simulate successful trust.

| Capability | Requirement |
| --- | --- |
| Rig | A read-only endpoint-principal resolution API or CLI contract that returns a stable principal reference and current policy decision |
| FreeIPA | Current Kvasir FreeIPA path remains reachable and has authority to create or verify host records |
| FleetDM | API access that can locate a host by a stable Fleet host ID or configured endpoint identifier and retrieve enrollment, last-seen, and policy status |
| Private CA | step-ca ACME or provisioner endpoint with an approved `endpoint-tls` profile and non-interactive renewal mechanism appropriate to the target OS |
| Trust bundle | Authenticated HTTPS or a managed local source with a pinned SHA-256 digest and version identifier |
| Target access | SSH/control access sufficient for the existing host enrollment path and installing the trust/certificate client |
| Bootstrap secrets | Connector credentials retrieved only through 1Password secret references or the host's approved runtime identity |

The user-facing command must identify which precondition is missing and the
owner of that dependency. It must never print the credential used to test it.

## User experience

### Command

```bash
# Plan only; no remote or local mutation.
kvasir enroll endpoint <target> \
  --rig-principal <rig-principal-ref> \
  --fleet-host-id <fleet-host-id>

# Apply only after the plan is acceptable.
kvasir enroll endpoint <target> \
  --rig-principal <rig-principal-ref> \
  --fleet-host-id <fleet-host-id> \
  --apply
```

`--rig-principal` and `--fleet-host-id` are explicit for the first release
so Kvasir cannot bind the wrong device based on a hostname guess. Optional
future resolution may infer them only after it emits a unique candidate and the
operator confirms it.

### Dry-run plan

A dry run prints a stable step list and creates no receipt file, IPA record,
certificate request, trust file, or target configuration change. It includes:

1. target address and detected OS;
2. requested Rig principal and policy decision reference;
3. expected Fleet host ID and current custody status;
4. FreeIPA host FQDN and whether create, verify, or recovery is required;
5. trust-bundle source, version, and pinned digest;
6. CA profile, expected subject/SANs, renewal location, and validation checks;
7. receipt destination and the conditions for **verified** versus **failed**.

The plan must mark any step that would require a manual prerequisite. It must
not call an external API with a mutation method in dry-run mode.

### Apply outcome

On success the command prints the enrollment ID, terminal state, certificate
expiry, trust-bundle digest, and local receipt path. On failure it prints the
failed step, safe next action, and receipt path. It exits nonzero for any
non-verified terminal state.

## Lifecycle and policy

The MVP records only the states it can prove:

| State | Entry condition |
| --- | --- |
| Candidate | Arguments parse and target is reachable enough to identify |
| Preflight failed | A required connector, policy reference, or identity check is missing |
| Enrolling | `--apply` has started; one or more mutable steps may be in progress |
| Enrolled | FreeIPA and target-local identity steps have completed |
| Trusted | Trust bundle and endpoint TLS credential have been installed and validated |
| Verified | Rig reference, Fleet custody, FreeIPA state, trust bundle, and certificate checks all have positive evidence |
| Failed | A step failed; receipt identifies completed work and the next safe action |

**Admitted**, **quarantined**, **revoked**, and automatic remediation are
intentionally not terminal MVP states. The receipt can declare
`admission_readiness: true` only when the endpoint is **Verified**; it cannot
claim network enforcement occurred.

The policy decision supplied by Rig must identify the endpoint class, owner,
allowed CA profile, required Fleet status, and whether FreeIPA membership is
required. A policy mismatch fails before mutation.

## Functional requirements

### FR-1: Command and input validation

- Add `enroll endpoint` to `bin/kvasir` without changing current command
  behavior.
- Accept `<target>`, `--rig-principal`, `--fleet-host-id`,
  `--apply`, `--force-reenroll`, and existing SSH routing flags where
  applicable.
- Reject empty, malformed, or ambiguous principal and Fleet identifiers before
  connector calls.
- Generate one UUID enrollment ID at the beginning of an apply operation.

### FR-2: Rig preflight

- Resolve the supplied Rig principal reference through a small `lib/rig.sh`
  adapter.
- Verify that it is an endpoint principal, has an owner, and is allowed by the
  returned enrollment policy.
- Persist only the stable reference, policy version/decision reference, and
  non-secret policy fields in the receipt.
- Do not mutate Rig in the MVP. A later contract may record the receipt
  centrally after Rig defines the governed write API.

### FR-3: Target identity and operating-system preflight

- Reach the target over the selected SSH route and capture hostname, FQDN,
  operating system, architecture, and non-sensitive network identity.
- Fail if the host's observed identity cannot be reconciled with the requested
  target and expected FreeIPA FQDN.
- Reuse existing macOS partial-state detection and require
  `--force-reenroll` for partial identity artifacts.
- Preserve existing local macOS break-glass accounts and Kvasir's managed-file
  boundaries.

### FR-4: Fleet custody verification

- Add `lib/fleet.sh` with an API-only adapter.
- Look up exactly the supplied Fleet host ID; do not match by display name.
- Verify host ID, serial/UUID or configured stable identifier, enrollment
  status, last-seen threshold, and policy status against the returned record.
- Record only the Fleet host ID, reported status, last-seen timestamp, and
  evidence digest/reference.
- Fail closed if Fleet reports a different device or an unhealthy state required
  by policy. A temporarily unreachable Fleet API is a preflight failure, not a
  warning.

### FR-5: FreeIPA enrollment

- Call existing `enroll-host` functionality through a reusable function or a
  controlled subprocess contract; do not duplicate IPA command construction.
- Verify the IPA host record and the target-local artifacts required by the
  detected OS.
- Preserve the existing OTP-based Linux path and the macOS Apple Directory
  Services plus Heimdal path.
- Record the host principal/FQDN and verification outcome, never a keytab or
  credential value.

### FR-6: Trust-bundle installation

- Add `lib/trust.sh` to retrieve a pinned, versioned internal trust bundle
  through an authenticated source.
- Verify the downloaded content SHA-256 against the policy/configured digest
  before installation.
- Install the bundle into the OS-appropriate trust store using managed,
  reversible file boundaries.
- Verify the installed bundle digest from the target after installation.
- Record source version and digest only. Certificate material is public but
  does not need to be duplicated in the receipt.

### FR-7: Private endpoint TLS credential

- Add `lib/ca.sh` for the approved private CA adapter; the first adapter is
  Smallstep step-ca.
- Request only the policy-approved `endpoint-tls` profile, subject, and SANs.
- The private key must be generated and stored on the endpoint with restrictive
  permissions. It must not transit the operator machine or receipt store.
- Validate chain, SANs, EKUs, issuer, not-before/not-after dates, and a minimum
  remaining validity threshold after issuance.
- Install an OS-appropriate renewal mechanism and verify it has a dry-run or
  status check.
- Record certificate fingerprint, issuer, subject, SANs, profile, expiry, and
  renewal check result; never private-key material.

### FR-8: Receipt creation

- Add `lib/receipt.sh` and write one JSON receipt per apply attempt under
  `${XDG_STATE_HOME:-$HOME/.local/state}/kvasir/receipts/`.
- Write atomically with owner-only permissions. A failure to write the receipt
  makes the overall command fail because audit evidence is a required outcome.
- Include completed and failed steps, timestamps, non-secret evidence, policy
  reference, next action, and terminal state.
- Support `kvasir receipt get <enrollment-id>` for local retrieval.
- Receipt JSON must validate against a versioned schema stored in the repo.

### FR-9: Failure and retry behavior

- Stop immediately at the first failed required step.
- Capture which steps completed and whether they are safe to retry.
- Do not automatically revoke a successfully issued host identity or
  certificate on failure; remediation is an explicit later action.
- Re-running with the same target must re-verify rather than unnecessarily
  rotate a keytab or certificate.
- `--force-reenroll` must list the identities and credentials it may rotate
  before apply proceeds.

## Receipt schema v1

```json
{
  "schema_version": "kvasir.enrollment.v1",
  "enrollment_id": "uuid",
  "created_at": "RFC3339",
  "terminal_state": "verified",
  "target": {
    "requested": "odin",
    "hostname": "odin",
    "fqdn": "odin.ravenhelm.dev",
    "os": "macos",
    "architecture": "arm64",
    "observed_identifiers": { "serial_or_uuid_hash": "sha256:..." }
  },
  "rig": {
    "principal_ref": "rig://...",
    "policy_decision_ref": "rig://...",
    "policy_version": "..."
  },
  "fleet": {
    "host_id": "123",
    "status": "healthy",
    "last_seen_at": "RFC3339",
    "evidence_ref": "sha256:..."
  },
  "freeipa": {
    "host_principal": "host/odin.ravenhelm.dev@RAVENHELM.DEV",
    "status": "verified"
  },
  "trust_bundle": {
    "version": "2026-07-23",
    "sha256": "..."
  },
  "certificate": {
    "profile": "endpoint-tls",
    "fingerprint_sha256": "...",
    "subject": "CN=odin.ravenhelm.dev",
    "sans": ["odin.ravenhelm.dev"],
    "not_after": "RFC3339",
    "renewal_status": "verified"
  },
  "steps": [
    { "name": "fleet.verify", "status": "passed", "started_at": "RFC3339", "finished_at": "RFC3339" }
  ],
  "admission_readiness": true,
  "next_action": null
}
```

The actual schema must reject unexpected secret-bearing keys such as
`private_key`, `password`, `token`, `keytab`, or `credential`.

## Architecture and file plan

| Path | Responsibility |
| --- | --- |
| `bin/kvasir` | Add command dispatch for endpoint enrollment and receipt retrieval |
| `bin/enroll-endpoint` | Top-level orchestration, plan rendering, state transitions, and exit codes |
| `lib/rig.sh` | Read-only principal and policy-decision adapter |
| `lib/fleet.sh` | Fleet host lookup and status normalization |
| `lib/trust.sh` | Pinned bundle retrieval, installation, and verification |
| `lib/ca.sh` | step-ca certificate request, validation, and renewal-status adapter |
| `lib/receipt.sh` | Atomic receipt creation, redaction guard, local query |
| `schemas/enrollment-receipt-v1.json` | Receipt validation contract |
| `tests/*endpoint*` | Unit, contract, dry-run, redaction, and integration coverage |
| `docs/runbook.md` | Operator prerequisites, expected plan, recovery, and verification |

Connector functions must follow one consistent shape: `preflight`, `plan`,
`apply`, `verify`, and `evidence`. A connector cannot convert an
unavailable integration into a passing result.

## Acceptance criteria

1. `kvasir enroll endpoint` is discoverable in `kvasir --help` and preserves
   all existing command behavior.
2. A dry run against fixtures makes zero mutating calls and creates no receipt.
3. An apply against a supported Linux fixture produces a schema-valid receipt
   only after Rig, Fleet, FreeIPA, trust-bundle, and certificate verification
   pass.
4. An apply against a supported macOS fixture preserves the documented local
   break-glass accounts and managed-file boundaries.
5. A mismatched Rig principal, Fleet host ID, or observed hardware identifier
   fails before FreeIPA or CA mutation.
6. A trust-bundle digest mismatch fails before installation and leaves no
   verified receipt.
7. A certificate with wrong SAN, issuer, EKU, or insufficient remaining
   lifetime fails the workflow.
8. Receipts contain no private keys, passwords, access tokens, keytabs, or
   1Password references that resolve to secret values.
9. A failed apply records the failed step, completed steps, and safe next action
   with a nonzero exit status.
10. A repeat apply on an already verified endpoint re-verifies and does not
    rotate keytabs or certificates unless `--force-reenroll` explicitly
    authorizes the relevant rotation.
11. The workflow performs no OPNsense mutation and does not claim network
    admission in its output or receipt.

## Test strategy

| Layer | Coverage |
| --- | --- |
| Unit | Argument parsing, state transitions, receipt serialization, redaction, trust-bundle digest validation, certificate metadata validation |
| Connector contract | Stubbed Rig, Fleet, FreeIPA, trust source, and CA responses for pass, unavailable, mismatch, and malformed evidence cases |
| Dry-run | Assert no stub records a mutation and no receipt path exists |
| Linux integration | Gated disposable host: FreeIPA verify, trust-store install, certificate validation, receipt proof |
| macOS integration | Gated disposable host: existing Kvasir macOS assertions plus trust-store and certificate validation |
| Regression | Existing test scripts run unchanged; endpoint orchestration must not regress `enroll-host`, service accounts, or user enrollment |

Live integrations are gated behind explicit environment variables and a
disposable target. A successful unit suite is not evidence that the target trust
store, Fleet custody, or CA renewal works in production.

## Rollout

1. Land the receipt schema, command skeleton, dry-run rendering, and fully
   stubbed connector contracts.
2. Add Rig and Fleet read-only connectors; validate against non-production or
   designated test principals.
3. Add trust-bundle and step-ca adapters on one disposable Linux endpoint.
4. Prove the macOS path on a designated disposable Mac while retaining
   break-glass access.
5. Publish the operator runbook and use the command for a small, named
   endpoint cohort.
6. Review receipts, renewal signals, and failure modes before proposing
   automated network admission as a separate governed milestone.

## Open decisions and explicit dependencies

| Decision or dependency | Required owner/outcome before production rollout |
| --- | --- |
| Rig enrollment decision contract | Stable endpoint principal and policy-decision response schema |
| Fleet healthy criteria | Last-seen threshold, policy status meaning, and immutable endpoint identifier |
| step-ca profile | Subject/SAN policy, renewal interval, key algorithm, EKUs, and revocation process |
| Trust-bundle publisher | Authenticated source, versioning, root rotation procedure, and pinned digest update mechanism |
| Receipt promotion | Central audit/event-plane destination for the post-MVP receipt projection |
| OPNsense admission | Separate policy, alias/rule model, maintenance window, rollback, and approval gate |

Until these are resolved, the MVP can implement contracts and fixtures but must
not label an endpoint production-verified.

