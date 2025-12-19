#!/usr/bin/env bash
set -euo pipefail

bootstrap_config() {
  if [[ -s "${LDAP_CONFIG_BOOTSTRAP_MARKER}" ]]; then
    log "Bootstrap already done (marker: ${LDAP_CONFIG_BOOTSTRAP_MARKER})."
    return 0
  fi

  if [[ -d /etc/ldap/slapd.d && -n "$(ls -A /etc/ldap/slapd.d 2>/dev/null || true)" ]]; then
    log "Detected existing /etc/ldap/slapd.d content; skipping config bootstrap."
    echo "existing-slapd.d" > "${LDAP_CONFIG_BOOTSTRAP_MARKER}"
    return 0
  fi

  log "Bootstrapping cn=config and database config..."

  local admin_hash
  if ! admin_hash="$(slappasswd -s "${LDAP_ADMIN_PASSWORD}")"; then
    die "Failed to hash admin password"
  fi

  mkdir -p /etc/ldap/slapd.d /var/lib/ldap /var/run/slapd

  # Minimal slapd.conf -> convert to cn=config
  cat > /etc/ldap/slapd.conf <<EOF
include /etc/ldap/schema/core.schema
include /etc/ldap/schema/cosine.schema
include /etc/ldap/schema/inetorgperson.schema
include /etc/ldap/schema/nis.schema

pidfile     /var/run/slapd/slapd.pid
argsfile    /var/run/slapd/slapd.args

modulepath  /usr/lib/ldap
moduleload  back_${LDAP_BACKEND}.la

#######################################################################
# Config db settings
#######################################################################
database config
access to * by dn.exact="gidNumber=0+uidNumber=0,cn=peercred,cn=external,cn=auth" manage by * none


database    ${LDAP_BACKEND}
maxsize     ${LDAP_DB_MAXSIZE}
suffix      "${LDAP_BASE_DN}"
rootdn      "${LDAP_ADMIN_DN}"
rootpw      ${admin_hash}
directory   /var/lib/ldap

index objectClass eq

access to attrs=userPassword,shadowLastChange
  by dn.exact="${LDAP_ADMIN_DN}" write
  by anonymous auth
  by self write
  by * none
access to *
  by dn.exact="${LDAP_ADMIN_DN}" write
  by users read
  by * none
EOF

  rm -rf /etc/ldap/slapd.d/*
  if ! slaptest -f /etc/ldap/slapd.conf -F /etc/ldap/slapd.d ; then
    cat /etc/ldap/slapd.conf >&2
    die "slaptest failed - see config above"
  fi

  chown -R openldap:openldap /etc/ldap/slapd.d /var/lib/ldap /var/run/slapd
  chmod 700 /etc/ldap/slapd.d || true

  echo "config bootstrapped $(date -Is)" > "${LDAP_CONFIG_BOOTSTRAP_MARKER}"
  if [[ "$(id -u)" == "0" ]]; then
    chown openldap:openldap "${LDAP_CONFIG_BOOTSTRAP_MARKER}" || true
  fi

  log "cn=config generated at /etc/ldap/slapd.d"
}