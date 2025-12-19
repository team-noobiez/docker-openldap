#!/usr/bin/env bash
set -euo pipefail

configure_memberof() {
  if [[ -s "${LDAP_MEMBEROF_CONFIG_MARKER}" ]]; then
    log "memberOf overlay already configured."
    return 0
  fi

  if [[ "${LDAP_ENABLE_MEMBEROF}" != "true" ]]; then
    log "memberOf overlay disabled (LDAP_ENABLE_MEMBEROF=${LDAP_ENABLE_MEMBEROF})."
    return 0
  fi

  if [[ ! -d /etc/ldap/slapd.d || -z "$(ls -A /etc/ldap/slapd.d 2>/dev/null || true)" ]]; then
    log "No cn=config found under /etc/ldap/slapd.d; skipping memberOf configuration."
    return 0
  fi

  log "Configuring memberOf + refint overlays..."

  # Start slapd temporarily
  /usr/sbin/slapd -F /etc/ldap/slapd.d -u openldap -g openldap -h "ldapi:///" -d 0 &
  local slapd_pid=$!

  if ! wait_for_ldapi; then
    kill "${slapd_pid}" || true
    die "slapd not ready for memberOf configuration."
  fi

  local module_dn
  module_dn="$(ldapsearch -Y EXTERNAL -H ldapi:/// -b cn=config "(objectClass=olcModuleList)" dn     | awk -F': ' '/^dn: /{print $2; exit}')"
  [[ -n "${module_dn}" ]] || die "Could not find olcModuleList DN under cn=config"

  # Discover DB DN for our suffix
  local db_dn
  db_dn="$(ldapsearch -Y EXTERNAL -H ldapi:/// -b cn=config     "(&(objectClass=olcDatabaseConfig)(olcSuffix=${LDAP_BASE_DN}))" dn     | awk -F': ' '/^dn: /{print $2; exit}')"
  [[ -n "${db_dn}" ]] || die "Could not find database DN for suffix ${LDAP_BASE_DN}"

  # Load memberof module
  cat > /tmp/memberof-module.ldif <<EOF
dn: ${module_dn}
changetype: modify
add: olcModuleLoad
olcModuleLoad: memberof
EOF

  local out=""
  if out="$(ldapmodify -Y EXTERNAL -H ldapi:/// -f /tmp/memberof-module.ldif 2>&1)"; then
    log "memberof module loaded"
  elif echo "$out" | grep -q "Type or value exists"; then
    log "memberof already loaded"
  else
    die "Failed to load memberof module: $out"
  fi

  # Add memberof overlay to database
  cat > /tmp/memberof-overlay.ldif <<EOF
dn: olcOverlay=memberof,${db_dn}
objectClass: olcOverlayConfig
objectClass: olcMemberOf
olcOverlay: memberof
olcMemberOfDangling: ${LDAP_MEMBEROF_DANGLING}
olcMemberOfRefInt: ${LDAP_MEMBEROF_REFINT}
olcMemberOfGroupOC: ${LDAP_MEMBEROF_GROUP_OC}
olcMemberOfMemberAD: ${LDAP_MEMBEROF_MEMBER_AD}
olcMemberOfMemberOfAD: ${LDAP_MEMBEROF_MEMBEROF_AD}
EOF

  if ldapadd -Y EXTERNAL -H ldapi:/// -f /tmp/memberof-overlay.ldif >/dev/null 2>&1; then
    log "memberOf overlay added successfully"
  else
    warn "memberOf overlay might already exist"
  fi

  # Load refint module (for cascade delete)
  cat > /tmp/refint-module.ldif <<EOF
dn: ${module_dn}
changetype: modify
add: olcModuleLoad
olcModuleLoad: refint
EOF

  ldapmodify -Y EXTERNAL -H ldapi:/// -f /tmp/refint-module.ldif

  # Add refint overlay
  cat > /tmp/refint-overlay.ldif <<EOF
dn: olcOverlay=refint,${db_dn}
objectClass: olcOverlayConfig
objectClass: olcRefintConfig
olcOverlay: refint
olcRefintAttribute: memberof member manager owner
EOF

  if ldapadd -Y EXTERNAL -H ldapi:/// -f /tmp/refint-overlay.ldif >/dev/null 2>&1; then
    log "refint overlay added successfully"
  else
    warn "refint overlay might already exist"
  fi

  # Stop temporary slapd
  kill "${slapd_pid}" || true
  wait "${slapd_pid}" 2>/dev/null || true

  echo "memberof configured $(date -Is)" > "${LDAP_MEMBEROF_CONFIG_MARKER}"
  if [[ "$(id -u)" == "0" ]]; then
    chown openldap:openldap "${LDAP_MEMBEROF_CONFIG_MARKER}" || true
  fi

  log "memberOf overlay configured."
}
