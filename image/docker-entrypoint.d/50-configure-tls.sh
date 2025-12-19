#!/usr/bin/env bash
set -euo pipefail

configure_tls() {
  if [[ ! -d /etc/ldap/slapd.d || -z "$(ls -A /etc/ldap/slapd.d 2>/dev/null || true)" ]]; then
    log "No cn=config found under /etc/ldap/slapd.d; skipping TLS configuration."
    return 0
  fi

  # Only apply TLS config when we have cn=config and either enabled or auto with files present.
  local enabled="${LDAP_TLS_ENABLED}"
  local have_cert="false"
  [[ -r "${LDAP_TLS_CRT_FILE}" && -r "${LDAP_TLS_KEY_FILE}" ]] && have_cert="true"

  if [[ "${enabled}" == "false" ]]; then
    log "TLS disabled (LDAP_TLS_ENABLED=false)."
    return 0
  fi

  if [[ "${enabled}" == "auto" && "${have_cert}" != "true" ]]; then
    log "TLS auto mode: cert/key not found; skipping TLS config."
    return 0
  fi

  if [[ "${have_cert}" != "true" ]]; then
    die "TLS enabled but cert/key missing: ${LDAP_TLS_CRT_FILE} / ${LDAP_TLS_KEY_FILE}"
  fi

  log "Preparing TLS certificates with secure permissions..."

  mkdir -p /etc/ldap/ssl
  chmod 700 /etc/ldap/ssl
  install -d -o root -g openldap -m 0750 /etc/ldap/ssl

  cp "${LDAP_TLS_CRT_FILE}" /etc/ldap/ssl/cert.crt
  cp "${LDAP_TLS_KEY_FILE}" /etc/ldap/ssl/cert.key
  if [[ -r "${LDAP_TLS_CA_FILE:-}" ]]; then
    cp "${LDAP_TLS_CA_FILE}" /etc/ldap/ssl/ca.crt
    chown openldap:openldap /etc/ldap/ssl/ca.crt
    LDAP_TLS_CA_FILE=/etc/ldap/ssl/ca.crt
  fi

  chown openldap:openldap /etc/ldap/ssl/cert.crt /etc/ldap/ssl/cert.key
  chmod 600 /etc/ldap/ssl/cert.key

  LDAP_TLS_CRT_FILE=/etc/ldap/ssl/cert.crt
  LDAP_TLS_KEY_FILE=/etc/ldap/ssl/cert.key

  log "Applying TLS settings to cn=config..."

  # Start slapd temporarily on ldapi to modify cn=config safely
  /usr/sbin/slapd -F /etc/ldap/slapd.d -u openldap -g openldap -h "ldapi:///" -d 0 &
  local slapd_pid=$!

  if ! wait_for_ldapi; then
    kill "${slapd_pid}" || true
    die "slapd not ready for TLS configuration."
  fi

  cat > /tmp/10-tls.ldif <<EOF
dn: cn=config
changetype: modify
replace: olcTLSCertificateFile
olcTLSCertificateFile: ${LDAP_TLS_CRT_FILE}
-
replace: olcTLSCertificateKeyFile
olcTLSCertificateKeyFile: ${LDAP_TLS_KEY_FILE}
EOF

  if [[ -r "${LDAP_TLS_CA_FILE}" ]]; then
    cat >> /tmp/10-tls.ldif <<EOF
-
replace: olcTLSCACertificateFile
olcTLSCACertificateFile: ${LDAP_TLS_CA_FILE}
EOF
  fi

  if [[ "${LDAP_REQUIRE_TLS}" == "true" ]]; then
    cat >> /tmp/10-tls.ldif <<EOF
-
replace: olcSecurity
olcSecurity: tls=1
EOF
  fi

  ldapmodify -Y EXTERNAL -H ldapi:/// -f /tmp/10-tls.ldif >/dev/null

  kill "${slapd_pid}" || true
  wait "${slapd_pid}" 2>/dev/null || true

  log "TLS configuration applied."
}
