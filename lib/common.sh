#!/usr/bin/env bash
# Kvasir common helpers — sourced by every bin/ script.
# Provides: logging, dry-run, env loading, error trap, retry, idempotency helpers.

set -euo pipefail

KVASIR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export KVASIR_ROOT

# ---------- env loading ----------
kvasir::load_env() {
  local env_file
  for env_file in \
      "${KVASIR_ENV_FILE:-}" \
      "${HOME}/.config/kvasir/env" \
      "${KVASIR_ROOT}/kvasir.env" \
      "${KVASIR_ROOT}/etc/kvasir.env"; do
    if [[ -n "${env_file}" && -f "${env_file}" ]]; then
      # shellcheck disable=SC1090
      source "${env_file}"
      kvasir::log debug "loaded env from ${env_file}"
      return 0
    fi
  done
  # fall through to example defaults if nothing else was found
  # shellcheck disable=SC1091
  source "${KVASIR_ROOT}/etc/kvasir.env.example"
  kvasir::log debug "loaded env from etc/kvasir.env.example (defaults)"
}

# ---------- logging ----------
# bash 3.2 compatible — no associative arrays.
KVASIR_LOG_LEVEL="${KVASIR_LOG_LEVEL:-info}"

kvasir::_level_n() {
  case "$1" in
    debug) echo 10 ;;
    info)  echo 20 ;;
    warn)  echo 30 ;;
    error) echo 40 ;;
    *)     echo 20 ;;
  esac
}

kvasir::log() {
  local level="$1"; shift
  local lvl_n thresh_n
  lvl_n=$(kvasir::_level_n "$level")
  thresh_n=$(kvasir::_level_n "$KVASIR_LOG_LEVEL")
  (( lvl_n < thresh_n )) && return 0
  local color reset="\033[0m"
  case "$level" in
    debug) color="\033[2m" ;;
    info)  color="\033[36m" ;;
    warn)  color="\033[33m" ;;
    error) color="\033[31m" ;;
    *)     color="" ;;
  esac
  printf "${color}[kvasir %-5s]${reset} %s\n" "$level" "$*" >&2
}

kvasir::die() { kvasir::log error "$*"; exit 1; }

# ---------- dry-run ----------
KVASIR_DRY_RUN="${KVASIR_DRY_RUN:-1}"

kvasir::is_dry_run() { [[ "$KVASIR_DRY_RUN" != "0" ]]; }

# Run a command unless dry-run; in dry-run, just log it.
kvasir::run() {
  if kvasir::is_dry_run; then
    kvasir::log info "DRY: $*"
    return 0
  fi
  kvasir::log debug "RUN: $*"
  "$@"
}

# Run a command but ALWAYS execute (read-only / probes). Logs at debug.
kvasir::probe() {
  kvasir::log debug "PROBE: $*"
  "$@"
}

# ---------- arg parsing ----------
kvasir::parse_common_flags() {
  local arg
  KVASIR_REMAINING=()
  while (( $# > 0 )); do
    arg="$1"; shift
    case "$arg" in
      --apply)    KVASIR_DRY_RUN=0 ;;
      --dry-run)  KVASIR_DRY_RUN=1 ;;
      --debug)    KVASIR_LOG_LEVEL=debug ;;
      --quiet)    KVASIR_LOG_LEVEL=warn ;;
      -h|--help)  KVASIR_WANT_HELP=1 ;;
      --)         KVASIR_REMAINING+=("$@"); break ;;
      *)          KVASIR_REMAINING+=("$arg") ;;
    esac
  done
}

# ---------- error trap ----------
kvasir::_on_err() {
  local exit_code=$?
  local line=$1
  kvasir::log error "failed at line ${line} with exit ${exit_code}"
  exit "$exit_code"
}
trap 'kvasir::_on_err $LINENO' ERR

# ---------- prereq check ----------
kvasir::require_cmd() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || kvasir::die "missing required command: $cmd"
  done
}

# ---------- ssh-sudo (optional 1Password-resolved password) ----------
# When the SSH-login user on a target host requires a sudo password (no
# NOPASSWD), set KVASIR_SUDO_PASSWORD_OP to an `op://vault/item/field` URI.
# kvasir::ssh_sudo will pipe the resolved password to `sudo -S` on the
# remote instead of failing on the password prompt.
#
# When KVASIR_SUDO_PASSWORD_OP is unset (default), the helper behaves
# identically to plain `ssh HOST "sudo CMD"` — preserving NOPASSWD-only
# backward compatibility.
KVASIR_SUDO_PASSWORD_OP="${KVASIR_SUDO_PASSWORD_OP:-}"
_KVASIR_SUDO_PW_CACHE=""

# Internal: resolve sudo pw from 1Password, cached in process memory.
# Returns empty string if KVASIR_SUDO_PASSWORD_OP is unset.
kvasir::_resolve_sudo_pw() {
  if [[ -z "${KVASIR_SUDO_PASSWORD_OP}" ]]; then
    printf ''
    return 0
  fi
  if [[ -z "${_KVASIR_SUDO_PW_CACHE}" ]]; then
    _KVASIR_SUDO_PW_CACHE="$(op read "${KVASIR_SUDO_PASSWORD_OP}" 2>/dev/null)" \
      || kvasir::die "could not resolve KVASIR_SUDO_PASSWORD_OP=${KVASIR_SUDO_PASSWORD_OP}"
  fi
  printf '%s' "${_KVASIR_SUDO_PW_CACHE}"
}

# kvasir::ssh_sudo HOST CMD [STDIN_DATA]
#
# Run `sudo CMD` on HOST via ssh. CMD is the remote-shell fragment, NOT
# including the leading `sudo` (the helper prepends it). If
# KVASIR_SUDO_PASSWORD_OP is set, the resolved password is piped before any
# STDIN_DATA on the remote command's stdin (sudo -S consumes the first line).
#
# Examples:
#   kvasir::ssh_sudo vakr "apt-get install -y freeipa-client"
#   kvasir::ssh_sudo vakr "bash -c 'cp /etc/hosts /etc/hosts.bak'"
#   kvasir::ssh_sudo vakr "tee /etc/ipa/ca.crt >/dev/null" "$CA_PEM"
kvasir::ssh_sudo() {
  local host="$1" cmd="$2" stdin="${3:-}"
  local pw
  pw="$(kvasir::_resolve_sudo_pw)"

  if [[ -n "$pw" ]]; then
    if [[ -n "$stdin" ]]; then
      local remote_tmp
      remote_tmp="$(mktemp /tmp/kvasir.XXXXXX)"
      ssh "$host" "umask 077; cat > '${remote_tmp}'" <<<"$stdin"
      {
        printf '%s\n' "$pw"
      } | ssh "$host" "sudo -S -p '' bash -lc 'eval \"\$1\" < \"\$2\"; rc=\$?; rm -f \"\$2\"; exit \$rc' _ \"$cmd\" '${remote_tmp}'"
    else
      {
        printf '%s\n' "$pw"
      } | ssh "$host" "sudo -S -p '' $cmd"
    fi
  else
    if [[ -n "$stdin" ]]; then
      ssh "$host" "sudo $cmd" <<<"$stdin"
    else
      ssh "$host" "sudo $cmd"
    fi
  fi
}

# Dry-run-aware wrapper. Same calling convention as kvasir::ssh_sudo.
# In dry-run mode, logs the would-be command without the password.
kvasir::run_ssh_sudo() {
  local host="$1" cmd="$2"
  if kvasir::is_dry_run; then
    kvasir::log info "DRY: ssh ${host} sudo ${cmd}"
    return 0
  fi
  kvasir::ssh_sudo "$@"
}
