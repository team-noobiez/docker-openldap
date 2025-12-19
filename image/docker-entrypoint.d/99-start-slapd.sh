#!/usr/bin/env bash
set -euo pipefail

start_slapd() {
  log "Starting slapd..."

  local hosts="ldapi:/// ldap://0.0.0.0:389"
  local enabled="${LDAP_TLS_ENABLED}"
  local have_cert="false"
  [[ -r "${LDAP_TLS_CRT_FILE}" && -r "${LDAP_TLS_KEY_FILE}" ]] && have_cert="true"

  if [[ "${enabled}" == "true" || ( "${enabled}" == "auto" && "${have_cert}" == "true" ) ]]; then
    hosts="${hosts} ldaps://0.0.0.0:636"
  fi

  exec /usr/sbin/slapd -u openldap -g openldap -h "${hosts}" -d "${LDAP_LOG_LEVEL}" "$@"
}
