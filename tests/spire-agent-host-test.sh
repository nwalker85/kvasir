#!/usr/bin/env bash
# The parent of a workload entry decides WHERE the SVID can be obtained.
#
# Before this, the parent was pinned to hrafngud's agent. Registering
# odinsrunes/live-hub (which runs on grani) produced an entry grani could never
# use and hrafngud could — the identity existed, on the wrong box, and the
# command reported success. `--install-agent` compounded it by logging "opt-in"
# and doing nothing at all, even under --apply.
set -euo pipefail

KVASIR_DIR="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

out="$("${KVASIR_DIR}/bin/kvasir" enroll workload odinsrunes/live-hub \
        --agent-host grani --selector 'unix:user:ravenhelm' --install-agent 2>&1)"

grep -q 'parent: spiffe://ravenmask.net/infra/spire-agent/grani' <<<"$out" \
  || fail "--agent-host did not move the parent; got:\n$out"
grep -q 'spiffe_id: spiffe://ravenmask.net/odinsrunes/live-hub' <<<"$out" \
  || fail "workload spiffe id wrong"

# The plan must state the selector apply will use, not the default.
grep -q 'selector: unix:user:ravenhelm' <<<"$out" \
  || fail "plan showed a different selector than --selector"

# --install-agent must describe a real install, not warn and continue.
grep -q 'spire-agent:' <<<"$out" || fail "--install-agent printed no plan"
grep -q 'host:       grani' <<<"$out" || fail "agent plan names the wrong host"
grep -qi 'will not run without a named host review' <<<"$out" \
  && fail "--install-agent is still the old no-op stub"

# Default is unchanged for callers that do not pass --agent-host.
d="$("${KVASIR_DIR}/bin/kvasir" enroll workload audio-app/frigate-recognizer 2>&1)"
grep -q 'parent: spiffe://ravenmask.net/infra/spire-agent/hrafngud' <<<"$d" \
  || fail "default parent regressed"

echo "ok: spire agent host"
