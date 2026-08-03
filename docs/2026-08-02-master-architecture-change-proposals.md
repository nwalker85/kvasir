# Master Architecture — Change Proposals

| Field | Value |
| --- | --- |
| Status | Proposed — each item independently acceptable/rejectable by Nate |
| Author | Claude (Supervisor), from the 2026-08-02 session |
| Target | Ravenhelm Identity Fabric — Master Architecture (ACCEPTED 2026-08-02, Outline `AD5C9FXJBI` / `~/docs/100-forensics/identity-architecture-master.md`) |
| Method | Reviewed against: tonight's Cloudflare-hairpin audit (live-verified), the PKI research fact-sheet, ADR-005/ADR-008, the Frigg/initiative charters, and the six-month identity-plane paper trail |

Eight proposals. P1–P3 close holes that will bite during Frigg M0–M1; P4–P6
are sequencing/contract fixes that are cheap now and expensive later; P7–P8
tighten seats the canon names but doesn't fully own. None alter the accepted
model (one spine, three planes, judged loop) — they complete it.

---

## P1 — Charter the trust fabric; three hard gates currently dangle

**Observation.** The master doc's hard gates reference "Project A internal
TLS" and "runestack ADR-007" — but neither exists as a chartered artifact.
ADR-007 is unwritten; the internal-TLS work is an un-adopted audit finding;
no initiative work-stream owns PKI. Meanwhile the enrolled plane's own
definition ("registration + **cryptographic enrollment**") presumes the PKI
that nothing is building, and today every `*.ravenmask.net` route is
deliberately cleartext (verified live: `entryPoints: [web]`, no TLS —
service keys and bearer tokens would cross VLANs in the clear the moment
traffic moves internal).

**Risk.** Frigg M0 starts 08-10 with a hard gate whose owner doesn't exist.
Gates without owners become waivers.

**Proposal.** Add a sixth work-stream project to the initiative — *Internal
Trust Fabric* — owning: (a) ADR-007, decision skeleton: SPIRE for workload
identity (k8s + Docker attestors cover Norns and Grani; SVIDs rotate in
hours), FreeIPA/certmonger for host+user certs, Let's Encrypt confined to
the public edge, SPIRE self-rooted initially with the `disk` UpstreamAuthority
re-parent to a Dogtag intermediate as a later config change; reconcile with
the kvasir PRD's existing step-ca reference (step-ca as the ACME/SSH-cert
front to the same hierarchy is the natural fit — the JumpCloud SSH-cert
story). (b) The Project A remediation (blocked on your split-horizon vs
rename ruling, still open from tonight). (c) The Traefik internal TLS
entrypoint, extending the proven `heimdall-agent-mtls` pattern.

**Lands in:** Linear (new project) + runestack `docs/adrs/ADR-007` + hard-gates
section pointing at real tickets.

---

## P2 — Define witness-unavailability semantics (candidate invariant D9)

**Observation.** D7 says every mutating action produces a receipt anchored to
the witness ledger. Nothing says what a producer does when **AAS is
unreachable at action time**. D6 answers this for evidence *acquisition*
(quarantine, never lose the capture window) but not for *provisioning*.
Tonight's audit is the empirical warning: rnd-api has been silently dead
behind a Cloudflare 1033 for an unknown period — services fail quietly here.

**Risk.** Without a rule, each producer improvises: some will block (identity
plane freezes when the witness hiccups), some will fire-and-forget (deeds
with no deed-record — the exact failure the Accountable AI thesis exists to
prevent).

**Proposal.** New invariant: **mutations refuse when the witness is
unreachable — fail closed — except an enumerated emergency class (revocation,
lock, session-kill) which executes immediately and queues its receipt in a
producer-local durable buffer with a monotonic local sequence, flagged
`witness_deferred: true`, reconciled on witness return and judgeable by Týr
with the deferral visible.** Safety actions must never wait on
infrastructure; everything else must never happen unwitnessed. The Frigg
receipt-schema ticket should carry the buffer/sequence fields from day one.

**Lands in:** master doc invariants (D9) + ADR-005 amendment + the receipt
schema ticket.

---

## P3 — Name the single key-holder inside the enrolled plane

**Observation.** The enrolled plane is defined as "FleetDM + FreeIPA host
principal + PKI" and called "the registry of record." Three systems, one
title. If Fleet and FreeIPA disagree about a host (they will — Fleet's Free
tier gates some server-side surfaces; enrollment sequences can half-complete),
the canon doesn't say which is the record.

**Risk.** The registry of record has the same ambiguity the person spine
just spent R1/R13 resolving — a World B waiting to be discovered on the
device axis.

**Proposal.** The **enrollment receipt (the kvasir-api provisioning fact,
witness-anchored, hardware handles stamped per R5/D5) is the registry of
record.** Fleet, FreeIPA host principals, and PKI issuance are *projections*
that must reconcile to it; disagreement between projections is a finding
(mirroring D3), surfaced in Frigg, never silently retagged. This also
contains the Fleet Free-tier API risk: if a Fleet surface turns out to be
premium-gated, the registry doesn't lose its record — only a projection
thins.

**Lands in:** master doc (plane table + a sentence in D2) + Frigg M1 design.

---

## P4 — Define one confidence vocabulary, once

**Observation.** Confidence is load-bearing in three invariants (D3
assertions carry it, D4 gradient orders it, D8 consumers render it) and in
Bifrost's roster line ("answers carry confidence, never launder inference
into fact"). Nowhere is it defined — scale, levels, or evidence-ref shape.

**Risk.** ioslogs, Heimdall, kvasir, and Frigg each invent a local dialect;
"truth flows down the confidence gradient" becomes unenforceable because the
gradient isn't comparable across planes; D8 rendering degrades into vibes.

**Proposal.** A one-page contract (runestack `docs/contracts/`) defining: the
ordinal levels (suggest: `attested > enrolled > asserted > inferred >
assumed` — note `attribution: assumed` from D5 already needs a seat), the
evidence-ref format `{source_system, handle, observed_at, method}`, and the
rule that cross-plane comparisons happen on this scale only. Designed inside
the Frigg receipt-schema ticket (it needs the fields anyway), adopted by
Heimdall assertions and future `kvasir_*`/`heimdall_*` Bifrost tools.

**Lands in:** new contract doc + identifier glossary row in the master doc.

---

## P5 — Break-glass: the plane that provisions everything has no offline story

**Observation.** Every console action requires FreeIPA + Zitadel + Rig +
Forseti live; kvasir-api provisions the very systems it authenticates
against; the April architecture notes planned FreeIPA HA (replica on vakr)
that was never chartered; and the ADR's halt-epoch/session-revoke latency
question (old open Q6) is still open. The circularity is real: an identity-
plane outage locks the operator out of the tools that fix identity-plane
outages.

**Risk.** The first bad FreeIPA day becomes an estate-wide lockout with the
remediation console among the casualties.

**Proposal.** (a) Charter the FreeIPA replica (vakr, per the April plan —
multi-master, survives one node). (b) Write the break-glass runbook as part
of Frigg M0: a documented, witnessed-after-the-fact emergency access path
(pre-provisioned local credential in OpenBao escrow + host-local access,
usable when the person plane is dark, every use minting a `witness_deferred`
receipt per P2 and an automatic Týr review). Break-glass that isn't designed
is just a hole; break-glass that is designed is an accountability feature.

**Lands in:** Linear (Identity Spine Remediation or new ops ticket) + a
master-doc hard gate: no M1 writable enrollment before the break-glass path
exists.

---

## P6 — Re-order RAV-1164 ahead of Frigg M0 read panes

**Observation.** R1 resolved that Heimdall `owner_user_id` ≠ `rig_user_id`,
with remediation at RAV-1164 (Identity Spine Remediation) and re-anchoring at
RAV-1192. Frigg M0 (start 08-10, panes by 09-18) is currently specced to
*build the mapping-chain workaround* into its read panes.

**Risk.** Frigg ships translation code whose deletion is already scheduled —
and if RAV-1164 lands mid-M0, the panes are wrong twice: once before, once
during the cutover.

**Proposal.** Either (a) sequence RAV-1164 to complete before the M0 read-
panes milestone — spine remediation is small compared to a console build and
the initiative window allows it — or (b) explicitly accept dual-path in the
Frigg charter with a deletion ticket pre-filed. Recommend (a); World B should
die before its first consumer is born.

**Lands in:** Linear sequencing across the two projects.

---

## P7 — Decide the agent DID issuer now, not at M4

**Observation.** ADR-008 is ACCEPTED and authorizes dómr schema design —
dómr attaches to the agent's continuity anchor, the DID. The DID issuer is
open (Q4: Rig vs dedicated service). Frigg M4 also gates on it, but M4 is
unchartered future work, which makes Q4 feel deferrable. It isn't: the dómr
schema being designed *now* must reference an anchor format that doesn't
exist.

**Risk.** Dómr schema work either stalls on Q4 informally, or picks an
anchor shape that pre-decides Q4 without a decision record.

**Proposal.** Pull the DID-issuer mini-ADR forward into the Accountable
Action Loop project's early tickets (before dómr schema freeze). My input to
that ADR: Rig already owns principal minting, provider bindings, and the
voice/MFA layer — issuing DIDs there keeps one minting authority; a
dedicated DID service is justified only if DIDs must outlive Rig itself,
which is a continuity question worth answering explicitly in the ADR rather
than by default.

**Lands in:** Linear (Accountable Action Loop) + ADR-008's open-questions
register.

---

## P8 — Give R7's threshold rule an enforcement seat

**Observation.** R7 decides *"network presence never mints an identity;
service consumption does; guest ≠ unlinked"* — a genuinely good rule with no
named enforcer. Heimdall observes network presence; many services observe
consumption; nothing states who evaluates the threshold or where the rule is
expressed.

**Risk.** The rule lives in prose; each service re-implements it; eventually
something (a captive portal, a media server, a future tenant app)
auto-creates person records on first sight and the spine grows unwitnessed
principals again — R13's duplicate-principal problem, re-created at the edge.

**Proposal.** Seat it explicitly: **kvasir-api is the only identity-minting
path** (it already is the sole provisioning path — make person-minting an
enumerated kvasir flow), the threshold expressed as Cedar policy evaluated by
Forseti like everything else, and observing systems (Heimdall included) may
only *propose* candidates into the merge queue that Frigg owns (R6). This
closes the loop with existing machinery; no new components.

**Lands in:** master doc (R7 row gains an owner) + Cedar corpus (the
console-action collab) + Frigg M2+ merge-queue design.

---

## Summary table

| # | One-liner | Cost if deferred |
| --- | --- | --- |
| P1 | Charter Internal Trust Fabric (ADR-007 + Project A + TLS entrypoint) | Frigg M0 opens with an ownerless hard gate |
| P2 | D9: fail closed on witness loss, emergency class queues `witness_deferred` | Unwitnessed deeds or a freezable estate — improvised per producer |
| P3 | Enrollment receipt IS the registry; Fleet/IPA/PKI are projections | A device-axis World B |
| P4 | One confidence vocabulary, defined in the receipt schema | D4/D8 unenforceable across planes |
| P5 | FreeIPA replica + designed break-glass (gate on M1) | Identity-plane outage locks out its own remediation |
| P6 | Land RAV-1164 before Frigg M0 read panes | Frigg ships pre-deprecated mapping code |
| P7 | DID-issuer mini-ADR now (dómr schema needs the anchor) | Q4 gets decided by accident |
| P8 | R7 enforced: kvasir mints, Forseti evaluates, observers propose | Unwitnessed principals return at the edge |

---

## Disposition (recorded 2026-08-03, from the amended master doc)

The master was amended the same evening, adjudicating this series alongside
the ioslogs auditor's M1–M8 and the architecture-repo proposal (R14/R15):

| # | Disposition | Where it landed |
| --- | --- | --- |
| P1 | **ADOPTED** | Sequencing §9.4 — Project A TLS gate "now owned by the Internal Trust Fabric stream (P1)" |
| P2 | **ADOPTED as D10** (numbering arbitration: D9 went to acquisition durability, M5) | Invariant D10, verbatim incl. emergency class + `witness_deferred` |
| P3 | **ADOPTED, extended** | Folded into amended D2 — and generalized beyond this proposal: Vidar CMDB + Mímir catalog are also projections (R14) |
| P4 | **ADOPTED** | Folded into amended D8 — ordinal scale + evidence-ref shape, designed in the Frigg receipt schema |
| P5 | **ADOPTED as hard gate** | Sequencing §9.4 — no M1 writable enrollment before break-glass. (FreeIPA-replica half not explicitly chartered — still open) |
| P6 | **ADOPTED as hard gate** (independently reached by the M-series) | Sequencing §9.4 — RAV-1164 before the M0 read-pane milestone |
| P7 | **Not visibly adopted** — M4 remains gated on open Q4; no early DID-issuer mini-ADR appears in the register or sequencing | Flag to Nate: intentional rejection or omission? |
| P8 | **Substantially covered** by R6 (observers propose via merge queue, decisions receipted through kvasir-api) + R7 resolution (provisioning via kvasir M2 mints) | The Cedar-expression of the threshold rule is the only sliver not recorded |
