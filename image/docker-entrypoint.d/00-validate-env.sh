#!/usr/bin/env bash
set -euo pipefail

validate_env() {
  # Required user-facing vars
  : "${LDAP_DOMAIN:=}"
  : "${LDAP_ORGANIZATION:=Example Org}"

  [[ -n "${LDAP_DOMAIN}" ]] || die "LDAP_DOMAIN is required (e.g., example.com)."

  file_env LDAP_ADMIN_PASSWORD ""
  [[ -n "${LDAP_ADMIN_PASSWORD}" ]] || die "LDAP_ADMIN_PASSWORD (or LDAP_ADMIN_PASSWORD_FILE) is required."

  : "${LDAP_LDAPI_SOCKET:=/var/run/slapd/ldapi}"
  if [[ -z "${LDAP_LDAPI_URI:-}" ]]; then
    local escaped
    escaped="$(printf '%s' "${LDAP_LDAPI_SOCKET}" | sed 's:/:%2F:g')"
    LDAP_LDAPI_URI="ldapi://${escaped}"
  fi
  export LDAP_LDAPI_SOCKET LDAP_LDAPI_URI

  local ldapi_dir
  ldapi_dir="$(dirname "${LDAP_LDAPI_SOCKET}")"
  mkdir -p "${ldapi_dir}"
  if [[ "$(id -u)" == "0" ]]; then
    chown openldap:openldap "${ldapi_dir}" || true
    chmod 0755 "${ldapi_dir}" || true
  fi

  rm -f "${LDAP_LDAPI_SOCKET}" || true

  # Optional vars
  : "${LDAP_BASE_DN:=}"
  if [[ -z "${LDAP_BASE_DN}" ]]; then
    LDAP_BASE_DN="$(domain_to_basedn "${LDAP_DOMAIN}")"
  fi
  export LDAP_BASE_DN

  : "${LDAP_ADMIN_DN:=cn=admin,${LDAP_BASE_DN}}"
  export LDAP_ADMIN_DN

  # TLS options
  : "${LDAP_TLS_ENABLED:=auto}"            # auto|true|false
  : "${LDAP_TLS_CRT_FILE:=/run/secrets/ldap/server.crt}"
  : "${LDAP_TLS_KEY_FILE:=/run/secrets/ldap/server.key}"
  : "${LDAP_TLS_CA_FILE:=/run/secrets/ldap/ca.crt}"
  : "${LDAP_REQUIRE_TLS:=false}"           # true|false
  export LDAP_TLS_ENABLED LDAP_TLS_CRT_FILE LDAP_TLS_KEY_FILE LDAP_TLS_CA_FILE LDAP_REQUIRE_TLS

  # validate enum: LDAP_TLS_ENABLED
  case "${LDAP_TLS_ENABLED}" in
    auto|true|false) ;; # valid
    *) die "Invalid LDAP_TLS_ENABLED value: '${LDAP_TLS_ENABLED}'. Must be one of: auto, true, false." ;;
  esac

  # validate bool: LDAP_REQUIRE_TLS
  case "${LDAP_REQUIRE_TLS}" in
    true|false) ;; 
    *) die "Invalid LDAP_REQUIRE_TLS value: '${LDAP_REQUIRE_TLS}'. Must be true|false." ;;
  esac

  # Bootstrap LDIF dir (mount your own files here)
  : "${LDAP_BOOTSTRAP_LDIF_DIR:=/bootstrap/ldif}"
  export LDAP_BOOTSTRAP_LDIF_DIR

  # Marker
  : "${LDAP_CONFIG_BOOTSTRAP_MARKER:=/var/lib/ldap/.config_bootstrapped}"
  : "${LDAP_DATA_BOOTSTRAP_MARKER:=/var/lib/ldap/.data_bootstrapped}"
  : "${LDAP_READONLY_USER_BOOTSTRAP_MARKER:=/var/lib/ldap/.readonly_user_bootstrapped}"
  : "${LDAP_MEMBEROF_CONFIG_MARKER:=/var/lib/ldap/.memberof_configured}"
  : "${LDAP_TLS_CONFIG_MARKER:=/var/lib/ldap/.tls_configured}"
  export LDAP_CONFIG_BOOTSTRAP_MARKER LDAP_DATA_BOOTSTRAP_MARKER LDAP_READONLY_USER_BOOTSTRAP_MARKER LDAP_MEMBEROF_CONFIG_MARKER LDAP_TLS_CONFIG_MARKER

  # Log level
  : "${LDAP_LOG_LEVEL:=256}"  # stats
  export LDAP_LOG_LEVEL

  # Backend
  : "${LDAP_BACKEND:=mdb}"    # mdb|hdb (mdb recommended)
  export LDAP_BACKEND

  # Database size
  : "${LDAP_DB_MAXSIZE:=1073741824}"  # 1GB
  export LDAP_DB_MAXSIZE

  # MemberOf overlay
  : "${LDAP_ENABLE_MEMBEROF:=true}"
  : "${LDAP_MEMBEROF_GROUP_OC:=groupOfNames}"
  : "${LDAP_MEMBEROF_MEMBER_AD:=member}"
  : "${LDAP_MEMBEROF_MEMBEROF_AD:=memberOf}"
  : "${LDAP_MEMBEROF_DANGLING:=ignore}"  # ignore|error
  : "${LDAP_MEMBEROF_REFINT:=TRUE}"
  export LDAP_ENABLE_MEMBEROF LDAP_MEMBEROF_GROUP_OC LDAP_MEMBEROF_MEMBER_AD LDAP_MEMBEROF_MEMBEROF_AD LDAP_MEMBEROF_DANGLING LDAP_MEMBEROF_REFINT

  case "${LDAP_ENABLE_MEMBEROF}" in true|false) ;; *) die "Invalid LDAP_ENABLE_MEMBEROF: '${LDAP_ENABLE_MEMBEROF}' (true|false)";; esac
  case "${LDAP_MEMBEROF_DANGLING}" in ignore|error) ;; *) die "Invalid LDAP_MEMBEROF_DANGLING: '${LDAP_MEMBEROF_DANGLING}' (ignore|error)";; esac
  case "${LDAP_MEMBEROF_REFINT}" in TRUE|FALSE|true|false) ;; *) die "Invalid LDAP_MEMBEROF_REFINT: '${LDAP_MEMBEROF_REFINT}' (TRUE|FALSE)";; esac

  LDAP_MEMBEROF_REFINT="$(echo "${LDAP_MEMBEROF_REFINT}" | tr '[:lower:]' '[:upper:]')"
  export LDAP_MEMBEROF_REFINT

  # Readonly user (osixia compatible)
  : "${LDAP_READONLY_USER:=false}"
  : "${LDAP_READONLY_USER_USERNAME:=readonly}"

  case "${LDAP_READONLY_USER}" in true|false) ;; *) die "Invalid LDAP_READONLY_USER: '${LDAP_READONLY_USER}' (true|false)";; esac

  if [[ -n "${LDAP_READONLY_USER_PASSWORD+x}" && -n "${LDAP_READONLY_USER_PASSWORD_FILE+x}" ]]; then
    die "Set only one: LDAP_READONLY_USER_PASSWORD OR LDAP_READONLY_USER_PASSWORD_FILE (not both)."
  fi

  if [[ "${LDAP_READONLY_USER}" == "true" ]]; then
    file_env LDAP_READONLY_USER_PASSWORD ""
    [[ -n "${LDAP_READONLY_USER_PASSWORD}" ]] || die \
      "LDAP_READONLY_USER is true, so LDAP_READONLY_USER_PASSWORD or LDAP_READONLY_USER_PASSWORD_FILE is required."
  fi

  export LDAP_READONLY_USER LDAP_READONLY_USER_USERNAME LDAP_READONLY_USER_PASSWORD

  # Replication
  : "${LDAP_REPLICATION:=false}"
  : "${LDAP_REPLICATION_HOSTS:=}"
  export LDAP_REPLICATION LDAP_REPLICATION_HOSTS

  case "${LDAP_REPLICATION}" in true|false) ;; *) die "Invalid LDAP_REPLICATION: '${LDAP_REPLICATION}' (true|false)";; esac
}
