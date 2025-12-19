#!/usr/bin/env bash
set -euo pipefail

bootstrap_readonly_user() {
  if [[ "${LDAP_READONLY_USER}" != "true" ]]; then
    return 0
  fi

  if [[ -z "${LDAP_READONLY_USER_PASSWORD}" ]]; then
    warn "LDAP_READONLY_USER=true but no password set; skipping"
    return 0
  fi

  if [[ -s "${LDAP_READONLY_USER_BOOTSTRAP_MARKER}" ]]; then
    log "Readonly user already configured"
    return 0
  fi

  log "Creating readonly user..."

  /usr/sbin/slapd -F /etc/ldap/slapd.d -u openldap -g openldap -h "ldapi:///" -d 0 &
  local slapd_pid=$!

  if ! wait_for_ldapi; then
    kill "${slapd_pid}" || true
    die "slapd not ready for readonly user creation"
  fi

  local readonly_hash
  readonly_hash="$(slappasswd -s "${LDAP_READONLY_USER_PASSWORD}")"

  cat > /tmp/readonly-user.ldif <<EOF
dn: cn=${LDAP_READONLY_USER_USERNAME},${LDAP_BASE_DN}
objectClass: simpleSecurityObject
objectClass: organizationalRole
cn: ${LDAP_READONLY_USER_USERNAME}
description: Readonly user
userPassword: ${readonly_hash}
EOF

  ldapadd -x -H ldapi:/// -D "${LDAP_ADMIN_DN}" -w "${LDAP_ADMIN_PASSWORD}" -f /tmp/readonly-user.ldif >/dev/null || warn "Readonly user might already exist"

  # add ACL
  local db_dn
  db_dn="$(ldapsearch -Y EXTERNAL -H ldapi:/// -LLL -b cn=config "(&(objectClass=olcDatabaseConfig)(olcSuffix=${LDAP_BASE_DN}))" dn | grep '^dn:' | head -1 | sed 's/^dn: //')"

  if [[ -z "${db_dn}" ]]; then
    db_dn="$(ldapsearch -Y EXTERNAL -H ldapi:/// -LLL -b cn=config \
      "(objectClass=olcMdbConfig)" dn 2>/dev/null \
      | grep '^dn:' | grep -v "cn=config" | head -1 | sed 's/^dn: //')"
  fi

  if [[ -n "${db_dn}" ]]; then
    log "Found database DN: ${db_dn}"

    cat > /tmp/readonly-acl.ldif <<EOF
dn: ${db_dn}
changetype: modify
add: olcAccess
olcAccess: to * by dn.exact="cn=${LDAP_READONLY_USER_USERNAME},${LDAP_BASE_DN}" read
EOF

    if ldapmodify -Y EXTERNAL -H ldapi:/// -f /tmp/readonly-acl.ldif >/dev/null 2>&1; then
      log "Readonly ACL added"
    else
      warn "Readonly ACL might already exist or failed to add"
    fi
  else
    warn "Could not detect DB DN; skipping readonly ACL"
  fi

  kill "${slapd_pid}" || true
  wait "${slapd_pid}" 2>/dev/null || true

  echo "readonly user bootstrapped $(date -Is)" > "${LDAP_READONLY_USER_BOOTSTRAP_MARKER}"
  if [[ "$(id -u)" == "0" ]]; then
    chown openldap:openldap "${LDAP_READONLY_USER_BOOTSTRAP_MARKER}" || true
  fi

  log "Readonly user created: cn=${LDAP_READONLY_USER_USERNAME},${LDAP_BASE_DN}"
}