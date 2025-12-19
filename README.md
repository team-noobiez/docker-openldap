# noobiez/openldap

[English](README.md) | [한국어](README.ko.md)

This repo is a minimal, opinionated OpenLDAP container image that:
- Generates `cn=config` on first run (stored in `/etc/ldap/slapd.d`)
- Creates a base DN + `ou=people` / `ou=groups`
- Applies additional LDIF files from `/bootstrap/ldif/*.ldif` (see `image/bootstrap/ldif/10-sample-group.ldif` for an example)
- Ships with optional readonly bind user + ACL compatible with osixia images
- Optionally configures TLS via mounted cert/key (auto/true/false, with `LDAP_REQUIRE_TLS` enforcement)
- Includes an end-to-end test harness (`image/test.sh`) that exercises all of the above (memberOf overlay, readonly user ACLs, bootstrap LDIFs, TLS auto/require/failure cases)

## Contents

- [Quick start](#quick-start)
- [Environment variables](#environment-variables)
- [Security Considerations](#security-considerations)
- [Bootstrap LDIFs](#bootstrap-ldifs)
- [Testing](#testing)
- [Roadmap (next steps)](#roadmap-next-steps)

## Quick start

```bash
cd example
docker compose up --build -d
```

Then test:

```bash
docker exec -it openldap ldapsearch -x -H ldap://localhost:389 -D "cn=admin,dc=example,dc=com" -w change-me-now -b "dc=example,dc=com" dn
```

## Environment variables

Required:
- `LDAP_DOMAIN` (e.g. `example.com`)
- `LDAP_ADMIN_PASSWORD` or `LDAP_ADMIN_PASSWORD_FILE`

Optional:
- `LDAP_BASE_DN` (default derived from `LDAP_DOMAIN`)
- `LDAP_ORGANIZATION` (default: `Example Org`)
- `LDAP_BOOTSTRAP_LDIF_DIR` (default: `/bootstrap/ldif`)
- `LDAP_TLS_ENABLED` = `auto|true|false` (default: `auto`)
- `LDAP_TLS_CRT_FILE`, `LDAP_TLS_KEY_FILE`, `LDAP_TLS_CA_FILE`
- `LDAP_REQUIRE_TLS` = `true|false` (default: `false`)

## Security Considerations

### Default ACLs

By default, this image configures a moderately permissive Access Control List (ACL). The rule `access to * by users read` allows any authenticated user to read most data within the directory. This is a sensible default for many use cases, but may not be suitable for environments containing sensitive information.

If you require stricter access control, it is strongly recommended to mount a custom LDIF file to modify the `olcAccess` attribute on the database configuration (`olcDatabase={1}mdb,cn=config`).

## Bootstrap LDIFs

Mount your custom LDIF files to `./bootstrap/ldif/*.ldif`. They are applied in lexicographic order after the base DN is created.

## Testing

Run the integration suite locally (requires Docker):

```bash
cd image
bash test.sh
```

The script rebuilds the image and runs several scenarios:
- default container health + memberOf overlay + readonly user ACL
- bootstrap LDIF application (verifies `uid=john,...` from `bootstrap/ldif`)
- TLS auto mode (self-signed cert) over both `ldaps://` and StartTLS
- TLS required mode (`LDAP_REQUIRE_TLS=true`) to ensure plain LDAP binds are rejected
- TLS enabled without certs (expected failure path)

All helper containers are cleaned up automatically at the end of the run.

GitHub Actions (`.github/workflows/ci.yml`) runs the same matrix on every push and pull request: the image is built once, saved as an artifact, and each job loads it to execute the smoke, readonly ACL, memberOf, bootstrap LDIF, TLS auto, TLS required, and TLS failure checks above.

## Roadmap (next steps)

- `_FILE` support for more secrets (bind users, replication creds)
- Overlays toggles (`memberof`, `ppolicy`, `syncprov`)
- Scheduled backups via `slapcat` (optional, opt-in)
- Kubernetes manifests + Helm chart
