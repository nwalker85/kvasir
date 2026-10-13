# Kvasir Documentation

Doc map for the `kvasir/docs/` directory. Read top-down for chronology of a topic; cross-link table below for navigation by purpose.

## macOS host enrollment

Status: **partial implementation, blocked on LDAP-bind redesign.** See postmortem first if you want the current picture.

| File | Type | Status | Purpose |
|---|---|---|---|
| [`mac-enrollment-design.md`](mac-enrollment-design.md) | Design spec | needs amendment | Original spec (2026-05-23). Approach D not yet documented; assumptions in §Architecture about direct plist writes are now known wrong. |
| [`mac-enrollment-plan.md`](mac-enrollment-plan.md) | Implementation plan | partial — bind_ldap section obsolete | 18 TDD tasks. Tasks 1–15 executed and tested. Task 16 (Darwin dispatch in `bin/enroll-host`) landed. Tasks for bind_ldap need rework once redesign lands. |
| [`mac-enrollment-postmortem.md`](mac-enrollment-postmortem.md) | Postmortem + status | current | What worked, what broke, six issues hit, suggested next architecture (`.mobileconfig` via `profiles(1)`). Read this before resuming. |

**Outline mirror:** [`[REF] macOS Host Enrollment via Kvasir`](https://outline.ravenhelm.dev/) — organization-wide audience version, kept in sync with the postmortem. (Created 2026-05-26.)

## Linux host enrollment

The Linux path is **production-working** and battle-tested across the fleet.

| File | Type | Purpose |
|---|---|---|
| [`runbook.md`](runbook.md) | Runbook | Operational procedures for enrolling/verifying/recovering Linux hosts. |
| [`service-account-automation-stage.md`](service-account-automation-stage.md) | Reference | Background on the host-scoped root service account model (`svc-<host>-root`) used by both Linux and macOS paths. |

**Authoritative recipe (not in this repo):** `memory/freeipa-fleet-enrollment-recipe.md` — the original recipe the Linux flow automates. Lives in personal-audio memory; kvasir codifies the recipe.

## Cross-cutting references

- **FreeIPA server fixes that happened during macOS work** are documented in the postmortem (§Issues 1) but apply to the whole fleet. The `ra_plugin = dogtag` addition to `/etc/ipa/default.conf` on the hrafngud container is the most important — it restored `Backend.ra` and unblocked `host-del` and any cert-touching command server-wide.
- **FreeIPA deployment bundle:** [`~/src/platforms/ravenhelm/freeipa-config/hrafngud/`](../../freeipa-config/hrafngud/) — bootstrap script + docker-compose. The `ra_plugin = dogtag` fix should be made permanent in the bootstrap to survive container rebuilds (TODO).

## Conventions

- File names lowercase, hyphenated.
- One topic per file. Status (current / partial / amended) goes at the top of each doc, not in the filename.
- Cross-link liberally between design/plan/postmortem of the same topic.
- Outline collection mirrors live in **Architecture** (long-lived design + decision docs) and **Operations** (runbooks). Kvasir's docs target the engineer reading the code; Outline mirrors target the broader org.

## Repo-level documents

- [`../README.md`](../README.md) — service overview, command table, prerequisites, quickstart, safety model.
- [`../etc/kvasir.env.example`](../etc/kvasir.env.example) — runtime config; treat as authoritative for environment variable names.
