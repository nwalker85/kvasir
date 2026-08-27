#!/usr/bin/env bash
# Certificate-authority routing. Kvasir requests; it does not sign.

pki::defaults() {
  KVASIR_STEPCA_URL="${KVASIR_STEPCA_URL:-https://10.10.20.10:9000}"
  KVASIR_STEPCA_FINGERPRINT="${KVASIR_STEPCA_FINGERPRINT:-}"
  KVASIR_STEPCA_ROOT_CN="${KVASIR_STEPCA_ROOT_CN:-lab-throwaway-20260820}"
  KVASIR_STEPCA_ENDPOINT_PROFILE="${KVASIR_STEPCA_ENDPOINT_PROFILE:-endpoint-tls}"
  KVASIR_STEPCA_CONTAINER="${KVASIR_STEPCA_CONTAINER:-step-ca}"
  KVASIR_SPIRE_HOST="${KVASIR_SPIRE_HOST:-${KVASIR_FREEIPA_HOST:-hrafngud-ts-svc}}"
  KVASIR_SPIRE_CONTAINER="${KVASIR_SPIRE_CONTAINER:-spire-server}"
  KVASIR_SPIRE_TRUST_DOMAIN="${KVASIR_SPIRE_TRUST_DOMAIN:-ravenhelm.dev}"
  KVASIR_SPIRE_BIND="${KVASIR_SPIRE_BIND:-10.10.20.10:8081}"
  KVASIR_IPA_USER_CERT_PROFILE="${KVASIR_IPA_USER_CERT_PROFILE:-caIPAserviceCert}"
  KVASIR_IPA_HOST_CERT_PROFILE="${KVASIR_IPA_HOST_CERT_PROFILE:-caIPAserviceCert}"
}

# Map a principal class to the issuing authority. Prints one token.
pki::authority_for() {
  local class="$1"
  pki::defaults
  case "$class" in
    user|host|service) echo dogtag ;;
    endpoint|endpoint-tls|trust-bundle|root) echo step-ca ;;
    workload) echo spire ;;
    *)
      kvasir::die "unknown principal class: ${class} (user|host|endpoint|service|workload)"
      ;;
  esac
}

pki::profile_for() {
  local class="$1"
  pki::defaults
  case "$class" in
    user|service) echo "${KVASIR_IPA_USER_CERT_PROFILE}" ;;
    host) echo "${KVASIR_IPA_HOST_CERT_PROFILE}" ;;
    endpoint|endpoint-tls) echo "${KVASIR_STEPCA_ENDPOINT_PROFILE}" ;;
    trust-bundle|root) echo "root-bundle" ;;
    workload) echo "spiffe-svid" ;;
    *) kvasir::die "unknown principal class: ${class}" ;;
  esac
}

pki::spiffe_id() {
  local workload="$1"
  pki::defaults
  printf 'spiffe://%s/%s\n' "${KVASIR_SPIRE_TRUST_DOMAIN}" "${workload#/}"
}

# Print a dry-run plan for issuing a cert of CLASS to PRINCIPAL.
pki::issue_plan() {
  local class="$1" principal="$2"
  local authority profile
  pki::defaults
  authority="$(pki::authority_for "$class")"
  profile="$(pki::profile_for "$class")"
  kvasir::log info "class=${class} principal=${principal} authority=${authority} profile=${profile}"
  case "$authority" in
    dogtag)
      cat <<EOF
plan:
  1. generate key + CSR on the subject (user workstation, host, or svc home)
  2. ipa cert-request <csr> --principal ${principal} --profile ${profile}
  3. attach cert to the IPA entry (user-add-cert / host certmonger)
  4. record fingerprint, issuer, notAfter — never the private key
forbidden: openssl req -x509 self-signed leftovers; Kvasir holding the Dogtag CA key
EOF
      ;;
    step-ca)
      cat <<EOF
plan:
  1. pin step-ca root ${KVASIR_STEPCA_ROOT_CN} fingerprint ${KVASIR_STEPCA_FINGERPRINT:-UNSET}
  2. request profile ${profile} from ${KVASIR_STEPCA_URL}
  3. private key stays on ${principal}; operator laptop is not a key escrow
  4. validate chain, SAN, EKU, remaining lifetime
forbidden: naming this root askr; copying the root key; issuing intermediates from Kvasir
EOF
      ;;
    spire)
      cat <<EOF
plan:
  1. register SPIFFE ID $(pki::spiffe_id "$principal") on ${KVASIR_SPIRE_CONTAINER}
  2. mint a join token (1Password), do not print it
  3. install a SPIRE agent only with --install-agent on a named host
  4. verify an SVID for that ID; chain to throwaway root via SPIRE ICA
forbidden: Kvasir becoming a second workload CA; installing agents fleet-wide
EOF
      ;;
  esac
}

pki::require_fingerprint() {
  pki::defaults
  [[ -n "${KVASIR_STEPCA_FINGERPRINT}" ]] \
    || kvasir::die "KVASIR_STEPCA_FINGERPRINT is unset — refuse to trust an unpinneable root"
}
