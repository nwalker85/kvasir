#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "${TEST_DIR}"' EXIT

ln -s "${ROOT}/bin/kvasir" "${TEST_DIR}/kvasir"

VERSION_OUTPUT="$("${TEST_DIR}/kvasir" version)"
if ! grep -Fq "root: ${ROOT}" <<<"${VERSION_OUTPUT}"; then
  printf 'FAIL: symlinked dispatcher resolved the wrong root\n%s\n' \
    "${VERSION_OUTPUT}" >&2
  exit 1
fi

HELP_OUTPUT="$("${TEST_DIR}/kvasir" enroll-host --help)"
if ! grep -Fq "Usage: kvasir enroll-host" <<<"${HELP_OUTPUT}"; then
  printf 'FAIL: symlinked dispatcher could not invoke enroll-host\n%s\n' \
    "${HELP_OUTPUT}" >&2
  exit 1
fi

printf 'PASS: symlinked dispatcher resolves the repository command tree\n'
