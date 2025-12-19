#!/usr/bin/env bash
set -euo pipefail

: "${LDAP_BASE_DN:=}"
: "${LDAP_LDAPI_URI:=ldapi://%2Fvar%2Frun%2Fslapd%2Fldapi}"

# Prefer SASL/EXTERNAL over LDAPI to avoid failures when simple binds require TLS.
if ldapsearch -Q -Y EXTERNAL -H "${LDAP_LDAPI_URI}" \
  -b "" -s base "(objectClass=*)" dn >/dev/null 2>&1; then
  exit 0
fi

if [[ -n "${LDAP_BASE_DN}" ]]; then
  ldapsearch -x -H "${LDAP_LDAPI_URI}" \
    -b "${LDAP_BASE_DN}" -s base "(objectClass=*)" dn >/dev/null 2>&1
else
  ldapsearch -x -H "${LDAP_LDAPI_URI}" \
    -b "" -s base "(objectClass=*)" dn >/dev/null 2>&1
fi
