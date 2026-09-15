#!/usr/bin/env bash
# step-ca adapter. Fetches the public root; never the signing key.

stepca::defaults() {
  pki::defaults
  KVASIR_STEPCA_HOST="${KVASIR_STEPCA_HOST:-${KVASIR_SPIRE_HOST:-${KVASIR_FREEIPA_HOST:-hrafngud-ts-svc}}}"
  KVASIR_STEPCA_CONTAINER="${KVASIR_STEPCA_CONTAINER:-step-ca}"
  KVASIR_STEPCA_PROVISIONER="${KVASIR_STEPCA_PROVISIONER:-nate}"
  KVASIR_STEPCA_INTERNAL_URL="${KVASIR_STEPCA_INTERNAL_URL:-https://127.0.0.1:9000}"
  KVASIR_STEPCA_ROOT_PATH="${KVASIR_STEPCA_ROOT_PATH:-/home/step/certs/root_ca.crt}"
}

stepca::ssh_host() {
  stepca::defaults
  printf '%s\n' "${KVASIR_STEPCA_HOST}"
}

stepca::roots_url() {
  pki::defaults
  printf '%s/roots.pem\n' "${KVASIR_STEPCA_URL%/}"
}

# Probe the CA. Read-only. Prints SHA-256 of the PEM body on success.
stepca::root_sha256() {
  local pem tmp
  tmp="$(mktemp)"
  if ! kvasir::probe curl -fsS --connect-timeout 5 -o "${tmp}" "$(stepca::roots_url)"; then
    rm -f "${tmp}"
    kvasir::die "step-ca roots unreachable at $(stepca::roots_url)"
  fi
  pem="$(openssl x509 -in "${tmp}" -outform der 2>/dev/null | openssl dgst -sha256 -r | awk '{print $1}')"
  rm -f "${tmp}"
  [[ -n "$pem" ]] || kvasir::die "step-ca roots.pem was not a certificate"
  printf '%s\n' "$pem"
}

stepca::verify_pin() {
  local got
  pki::require_fingerprint
  got="$(stepca::root_sha256)"
  if [[ "${got}" != "${KVASIR_STEPCA_FINGERPRINT}" ]]; then
    kvasir::die "step-ca root fingerprint mismatch: got ${got} wanted ${KVASIR_STEPCA_FINGERPRINT}"
  fi
  kvasir::log info "step-ca root pin ok cn=${KVASIR_STEPCA_ROOT_CN} sha256=${got}"
}

stepca::bundle_plan() {
  pki::defaults
  cat <<EOF
trust-bundle:
  source: $(stepca::roots_url)
  expected_cn: ${KVASIR_STEPCA_ROOT_CN}
  expected_sha256: ${KVASIR_STEPCA_FINGERPRINT:-UNSET}
  install: OS trust store + IPA clients via ipa-certupdate after Dogtag reparent
  note: this is the lab throwaway root, not askr
EOF
}

stepca::discover_pin() {
  local got cn
  got="$(stepca::root_sha256)"
  cn="$(curl -fsS --connect-timeout 5 "$(stepca::roots_url)" | openssl x509 -noout -subject 2>/dev/null | sed 's/subject=CN = //;s/subject=CN=//')"
  kvasir::log info "step-ca discover cn=${cn:-unknown} sha256=${got}"
  printf '%s\n' "$got"
}

stepca::preflight() {
  stepca::defaults
  kvasir::log info "step-ca: host=${KVASIR_STEPCA_HOST} container=${KVASIR_STEPCA_CONTAINER} url=${KVASIR_STEPCA_URL}"
  if kvasir::is_dry_run; then
    kvasir::log info "DRY: curl $(stepca::roots_url)"
    return 0
  fi
  stepca::root_sha256 >/dev/null
}

stepca::provisioner_password() {
  stepca::defaults
  [[ -n "${KVASIR_STEPCA_PROVISIONER_PASSWORD_OP:-}" ]] \
    || kvasir::die "KVASIR_STEPCA_PROVISIONER_PASSWORD_OP unset — required to sign CSRs"
  op read "${KVASIR_STEPCA_PROVISIONER_PASSWORD_OP}" 2>/dev/null \
    || kvasir::die "could not read KVASIR_STEPCA_PROVISIONER_PASSWORD_OP"
}

# Sign a CSR generated on the subject. Writes the leaf cert to CRT_OUT locally.
stepca::sign_csr() {
  local csr="$1" crt_out="$2" principal="${3:-}"
  local csr_pem pw remote_script
  stepca::defaults
  [[ -f "$csr" ]] || kvasir::die "CSR not found: ${csr}"

  if kvasir::is_dry_run; then
    kvasir::log info "DRY: step ca sign ${csr} -> ${crt_out} via ${KVASIR_STEPCA_CONTAINER} issuer=${KVASIR_STEPCA_PROVISIONER}"
    return 0
  fi

  stepca::verify_pin
  pw="$(stepca::provisioner_password)"
  csr_pem="$(cat "$csr")"

  remote_script="$(cat <<'EOS'
set -euo pipefail
umask 077
csr=/tmp/kvasir.csr
crt=/tmp/kvasir.crt
pw=/tmp/kvasir.pw
trap 'rm -f "$csr" "$crt" "$pw"' EXIT
cat >"$csr"
printf '%s' "$PW" >"$pw"
set_args=(--ca-url "$CA_URL" --root "$ROOT_PATH" --issuer "$ISSUER" --provisioner-password-file "$pw")
if [[ -n "$PRINC" ]]; then
  set_args+=(--set "dnsNames=$PRINC")
fi
step ca sign "$csr" "$crt" "${set_args[@]}" >/dev/null
cat "$crt"
EOS
)"

  {
    printf '%s\n' "$csr_pem"
  } | ssh -o BatchMode=yes -o ConnectTimeout=8 "$(stepca::ssh_host)" \
    "PW=$(printf '%q' "$pw") PRINC=$(printf '%q' "$principal") CA_URL=$(printf '%q' "$KVASIR_STEPCA_INTERNAL_URL") ROOT_PATH=$(printf '%q' "$KVASIR_STEPCA_ROOT_PATH") ISSUER=$(printf '%q' "$KVASIR_STEPCA_PROVISIONER") docker exec -i '${KVASIR_STEPCA_CONTAINER}' bash -lc $(printf '%q' "$remote_script")" \
    >"$crt_out" \
    || kvasir::die "step-ca sign failed for ${csr}"

  [[ -s "$crt_out" ]] || kvasir::die "step-ca sign produced empty cert: ${crt_out}"
  kvasir::log info "step-ca signed CSR -> ${crt_out}"
}
