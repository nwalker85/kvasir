#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KVASIR="${ROOT}/bin/kvasir"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

HELP="$("${KVASIR}" enroll-host --help)"
grep -Fq "Usage: kvasir enroll-host" <<<"${HELP}" \
  || fail "hyphenated enroll-host help broke"

NESTED="$("${KVASIR}" enroll host --help)"
grep -Fq "Usage: kvasir enroll-host" <<<"${NESTED}" \
  || fail "nested enroll host did not reach enroll-host"

CERT="$("${KVASIR}" cert --help)"
grep -Fq "Usage: kvasir cert" <<<"${CERT}" \
  || fail "cert help missing"

EP="$("${KVASIR}" enroll endpoint --help)"
grep -Fq "Usage: kvasir enroll endpoint" <<<"${EP}" \
  || fail "enroll endpoint help missing"

WL="$("${KVASIR}" enroll workload --help)"
grep -Fq "Usage: kvasir enroll workload" <<<"${WL}" \
  || fail "enroll workload help missing"

TOP="$("${KVASIR}" --help)"
grep -Fq "cert issue" <<<"${TOP}" || fail "top-level help missing cert"

printf 'ok - nested dispatcher\n'
