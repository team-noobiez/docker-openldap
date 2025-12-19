#!/usr/bin/env bash
: "${DEBUG:=false}"
if [[ "${DEBUG}" == "true" ]]; then
  set -x
  export LDAP_LOG_LEVEL=any
fi

set -euo pipefail

# --- helpers ---------------------------------------------------------------

log()  { echo "[$(date -Is)] $*"; }
warn() { echo "[$(date -Is)] WARN: $*" >&2; }
die()  { echo "[$(date -Is)] ERROR: $*" >&2; exit 1; }

# read env var or *_FILE (docker secrets pattern)
# usage: file_env VAR [default]
file_env() {
  local var="$1"
  local def="${2:-}"
  local fileVar="${var}_FILE"
  local val="${!var-}"
  local fileVal="${!fileVar-}"

  if [[ -n "${val}" && -n "${fileVal}" ]]; then
    die "Both $var and $fileVar are set (choose one)."
  fi

  if [[ -n "${fileVal}" ]]; then
    [[ -r "${fileVal}" ]] || die "$fileVar points to unreadable file: ${fileVal}"
    val="$(< "${fileVal}")"
  fi

  if [[ -z "${val}" ]]; then
    val="${def}"
  fi

  export "${var}=${val}"
  unset "${fileVar}"
}

domain_to_basedn() {
  local d="$1"
  local out=""
  IFS='.' read -ra parts <<< "$d"
  for p in "${parts[@]}"; do
    [[ -n "$out" ]] && out+=","
    out+="dc=${p}"
  done
  echo "$out"
}

first_dc() {
  local d="$1"
  echo "${d%%.*}"
}

wait_for_ldapi() {
  local tries=50
  while (( tries-- > 0 )); do
    if ldapsearch -x -H "${LDAP_LDAPI_URI}" -b "" -s base "(objectClass=*)" dn >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.2
  done
  return 1
}

run_as_openldap() {
  # Debian's slapd runs as openldap; we keep root for bootstrap then exec slapd with -u/-g
  "$@"
}

cleanup() {
  log "Shutting down gracefully..."
  if [[ -n "${slapd_pid:-}" ]]; then
    kill -TERM "${slapd_pid}" 2>/dev/null || true
    wait "${slapd_pid}" 2>/dev/null || true
  fi
}

trap cleanup SIGTERM SIGINT

# --- load steps ------------------------------------------------------------

for f in /docker-entrypoint.d/*.sh; do
  # shellcheck disable=SC1090
  source "$f"
done

main() {
  local steps=(
    validate_env
    bootstrap_config
    configure_memberof
    bootstrap_data
    bootstrap_readonly_user
    configure_tls
  )

  for step in "${steps[@]}"; do
    log "Running: ${step}"
    "$step"
  done

  start_slapd "$@"
}

main "$@"
