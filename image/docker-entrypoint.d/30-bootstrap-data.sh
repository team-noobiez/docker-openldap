#!/usr/bin/env bash
set -euo pipefail

bootstrap_data() {
  if [[ -s "${LDAP_DATA_BOOTSTRAP_MARKER}" ]]; then
    return 0
  fi

  log "Starting slapd temporarily for bootstrap..."

  install -d -o openldap -g openldap -m 0755 /run/slapd
  rm -f "${LDAP_LDAPI_SOCKET}" || true

  # Start slapd with ldapi + ldap (no ldaps yet)
    /usr/sbin/slapd -F /etc/ldap/slapd.d -u openldap -g openldap -h "ldapi:/// ldap://0.0.0.0:389" -d "${LDAP_LOG_LEVEL}" &
  local slapd_pid=$!

  if ! wait_for_ldapi; then
    kill "${slapd_pid}" || true
    die "slapd did not become ready on ldapi:/// during bootstrap."
  fi

  local dc0
  dc0="$(first_dc "${LDAP_DOMAIN}")"

  # Base tree
  cat > /tmp/00-base.ldif <<EOF
dn: ${LDAP_BASE_DN}
objectClass: top
objectClass: dcObject
objectClass: organization
o: ${LDAP_ORGANIZATION}
dc: ${dc0}

dn: ou=people,${LDAP_BASE_DN}
objectClass: top
objectClass: organizationalUnit
ou: people

dn: ou=groups,${LDAP_BASE_DN}
objectClass: top
objectClass: organizationalUnit
ou: groups
EOF

  log "Adding base DN and default OUs..."
  if ! ldapadd -x -H ldapi:/// -D "${LDAP_ADMIN_DN}" -w "${LDAP_ADMIN_PASSWORD}" -f /tmp/00-base.ldif; then
    log "Base DN might already exist or other error occurred"
  fi

  # Apply user-provided bootstrap LDIFs (lexicographic order)
  if [[ -d "${LDAP_BOOTSTRAP_LDIF_DIR}" ]]; then
    shopt -s nullglob
    local files=( "${LDAP_BOOTSTRAP_LDIF_DIR}"/*.ldif )
    if (( ${#files[@]} > 0 )); then
      log "Applying custom bootstrap LDIFs from ${LDAP_BOOTSTRAP_LDIF_DIR} ..."
      local failed=0
      for f in "${files[@]}"; do
        log " - ldapadd ${f}"
        if ! ldapadd -x -H ldapi:/// -D "${LDAP_ADMIN_DN}" -w "${LDAP_ADMIN_PASSWORD}" -f "${f}"; then
          warn "Failed to apply ${f} (continuing...)"
          ((failed++))
        fi
      done
      if (( failed > 0 )); then
        warn "${failed} LDIF file(s) failed to apply"
      fi
    fi
  fi

  # Stop temporary slapd
  kill "${slapd_pid}" || true
  wait "${slapd_pid}" 2>/dev/null || true

  echo "data bootstrapped $(date -Is)" > "${LDAP_DATA_BOOTSTRAP_MARKER}"
  if [[ "$(id -u)" == "0" ]]; then
    chown openldap:openldap "${LDAP_DATA_BOOTSTRAP_MARKER}" || true
  fi

  log "Bootstrap data complete."
}
