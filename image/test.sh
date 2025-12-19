#!/bin/bash
# test.sh

set -e

CONTAINER_NAME="test-ldap"
IMAGE_NAME="my-openldap:test"
TLS_CONTAINER_NAME="test-ldap-tls"
TLS_REQUIRE_CONTAINER="test-ldap-tls-require"
TLS_FAIL_CONTAINER="test-ldap-tls-fail"
BOOTSTRAP_CONTAINER="test-ldap-bootstrap"
TLS_TMP_DIR=""

# Cleanup function
cleanup() {
  echo "=== Cleanup ==="
  docker stop ${CONTAINER_NAME} 2>/dev/null || true
  docker rm -v ${CONTAINER_NAME} 2>/dev/null || true
  docker stop ${TLS_CONTAINER_NAME} 2>/dev/null || true
  docker rm -v ${TLS_CONTAINER_NAME} 2>/dev/null || true
  docker stop ${TLS_REQUIRE_CONTAINER} 2>/dev/null || true
  docker rm -v ${TLS_REQUIRE_CONTAINER} 2>/dev/null || true
  docker stop ${TLS_FAIL_CONTAINER} 2>/dev/null || true
  docker rm -v ${TLS_FAIL_CONTAINER} 2>/dev/null || true
  docker stop ${BOOTSTRAP_CONTAINER} 2>/dev/null || true
  docker rm -v ${BOOTSTRAP_CONTAINER} 2>/dev/null || true
  if [[ -n "${TLS_TMP_DIR}" && -d "${TLS_TMP_DIR}" ]]; then
    rm -rf "${TLS_TMP_DIR}" || true
  fi
}

generate_tls_materials() {
  local dir
  dir="$(mktemp -d)"
  openssl req -x509 -nodes -newkey rsa:2048 \
    -keyout "${dir}/server.key" \
    -out "${dir}/server.crt" \
    -days 1 -subj "/CN=localhost" >/dev/null 2>&1
  cp "${dir}/server.crt" "${dir}/ca.crt"
  chmod 644 "${dir}/server.crt" "${dir}/server.key" "${dir}/ca.crt"
  echo "${dir}"
}

# Cleanup on exit
trap cleanup EXIT

# Clean up any existing container
cleanup

echo "=== Building image ==="
docker buildx build --no-cache -t ${IMAGE_NAME} . --load

echo ""
echo "=== Starting container ==="
docker run -d --name test-ldap \
  -e LDAP_DOMAIN=example.com \
  -e LDAP_ORGANIZATION="Test Org" \
  -e LDAP_ADMIN_PASSWORD=admin123 \
  -e LDAP_ENABLE_MEMBEROF=true \
  -e LDAP_READONLY_USER=true \
  -e LDAP_READONLY_USER_PASSWORD=readonly123 \
  -p 389:389 \
  ${IMAGE_NAME}

echo ""
echo "=== Waiting for startup ==="
sleep 8

# Show startup logs
docker logs ${CONTAINER_NAME}

echo ""
echo "=== Waiting for healthy status ==="
for i in {1..30}; do
  if docker exec ${CONTAINER_NAME} /usr/local/bin/healthcheck.sh 2>/dev/null; then
    echo "✓ Container is healthy"
    break
  fi
  if [ $i -eq 30 ]; then
    echo "✗ Container failed to become healthy"
    docker logs ${CONTAINER_NAME}
    exit 1
  fi
  echo -n "."
  sleep 1
done

echo ""
echo "=== Checking what's in the database ==="
docker exec ${CONTAINER_NAME} ldapsearch -x -LLL -H ldapi:/// \
  -D "cn=admin,dc=example,dc=com" \
  -w admin123 \
  -b "dc=example,dc=com" \
  -s base "(objectClass=*)" dn 2>&1 || true

echo ""
echo "=== Testing admin login ==="
if docker exec ${CONTAINER_NAME} ldapsearch -x -LLL \
  -D "cn=admin,dc=example,dc=com" \
  -w admin123 \
  -b "dc=example,dc=com" \
  "(objectClass=organizationalUnit)" dn; then
  echo "✓ Admin login successful"
else
  echo "✗ Admin login failed"
  echo ""
  echo "=== Debugging: Check slapd.d config ==="
  docker exec ${CONTAINER_NAME} cat /etc/ldap/slapd.d/cn=config/olcDatabase={1}mdb.ldif 2>&1 | head -20
  exit 1
fi

echo ""
echo "=== Testing readonly user ==="
if docker exec ${CONTAINER_NAME} ldapsearch -x -LLL \
  -D "cn=readonly,dc=example,dc=com" \
  -w readonly123 \
  -b "dc=example,dc=com" \
  "(objectClass=organizationalUnit)" dn; then
  echo "✓ Readonly user login successful"
else
  echo "✗ Readonly user login failed"
  exit 1
fi

echo ""
echo "=== Testing readonly user cannot write ==="
if docker exec -i ${CONTAINER_NAME} ldapadd -x \
  -D "cn=readonly,dc=example,dc=com" \
  -w readonly123 2>&1 <<EOF | grep -q "Insufficient access"
dn: uid=test,ou=people,dc=example,dc=com
objectClass: inetOrgPerson
uid: test
cn: Test
sn: User
EOF
then
  echo "✓ Readonly user correctly denied write access"
else
  echo "✗ Readonly user should not have write access"
fi

echo ""
echo "=== Adding test user ==="
if docker exec -i ${CONTAINER_NAME} ldapadd -x \
  -D "cn=admin,dc=example,dc=com" \
  -w admin123 <<EOF
dn: uid=testuser,ou=people,dc=example,dc=com
objectClass: top
objectClass: person
objectClass: organizationalPerson
objectClass: inetOrgPerson
uid: testuser
cn: Test User
sn: User
mail: test@example.com
EOF
then
  echo "✓ Test user added"
else
  echo "✗ Failed to add test user"
  exit 1
fi

echo ""
echo "=== Creating test group ==="
if docker exec -i ${CONTAINER_NAME} ldapadd -x \
  -D "cn=admin,dc=example,dc=com" \
  -w admin123 <<EOF
dn: cn=developers,ou=groups,dc=example,dc=com
objectClass: top
objectClass: groupOfNames
cn: developers
description: Development team
member: cn=admin,dc=example,dc=com
EOF
then
  echo "✓ Test group created"
else
  echo "✗ Failed to create test group"
  exit 1
fi

echo ""
echo "=== Adding user to group ==="
if docker exec -i ${CONTAINER_NAME} ldapmodify -x \
  -D "cn=admin,dc=example,dc=com" \
  -w admin123 <<EOF
dn: cn=developers,ou=groups,dc=example,dc=com
changetype: modify
add: member
member: uid=testuser,ou=people,dc=example,dc=com
EOF
then
  echo "✓ User added to group"
else
  echo "✗ Failed to add user to group"
  exit 1
fi

echo ""
echo "=== Checking memberOf attribute ==="
MEMBEROF_RESULT=$(docker exec ${CONTAINER_NAME} ldapsearch -x -LLL \
  -D "cn=admin,dc=example,dc=com" \
  -w admin123 \
  -b "uid=testuser,ou=people,dc=example,dc=com" \
  "(objectClass=*)" memberOf 2>/dev/null)

if echo "$MEMBEROF_RESULT" | grep -q "memberOf: cn=developers,ou=groups,dc=example,dc=com"; then
  echo "✓ memberOf attribute correctly set:"
  echo "$MEMBEROF_RESULT"
else
  echo "✗ memberOf attribute not found"
  echo "Result was:"
  echo "$MEMBEROF_RESULT"
  exit 1
fi

echo ""
echo "=== Removing user from group ==="
if docker exec -i ${CONTAINER_NAME} ldapmodify -x \
  -D "cn=admin,dc=example,dc=com" \
  -w admin123 <<EOF
dn: cn=developers,ou=groups,dc=example,dc=com
changetype: modify
delete: member
member: uid=testuser,ou=people,dc=example,dc=com
EOF
then
  echo "✓ User removed from group"
else
  echo "✗ Failed to remove user from group"
  exit 1
fi

echo ""
echo "=== Verifying memberOf removed ==="
MEMBEROF_RESULT=$(docker exec ${CONTAINER_NAME} ldapsearch -x -LLL \
  -D "cn=admin,dc=example,dc=com" \
  -w admin123 \
  -b "uid=testuser,ou=people,dc=example,dc=com" \
  "(objectClass=*)" memberOf 2>/dev/null || true)

if echo "$MEMBEROF_RESULT" | grep -q "memberOf:"; then
  echo "✗ memberOf attribute should have been removed"
  echo "$MEMBEROF_RESULT"
  exit 1
else
  echo "✓ memberOf attribute correctly removed"
fi

echo ""
echo "=== Testing bootstrap LDIF application ==="
BOOTSTRAP_DIR="$(pwd)/bootstrap/ldif"
if [[ ! -d "${BOOTSTRAP_DIR}" ]]; then
  echo "✗ Bootstrap LDIF directory not found: ${BOOTSTRAP_DIR}"
  exit 1
fi

docker stop ${BOOTSTRAP_CONTAINER} 2>/dev/null || true
docker rm -v ${BOOTSTRAP_CONTAINER} 2>/dev/null || true

docker run -d --name ${BOOTSTRAP_CONTAINER} \
  -e LDAP_DOMAIN=example.com \
  -e LDAP_ORGANIZATION="Test Org" \
  -e LDAP_ADMIN_PASSWORD=admin123 \
  -v "${BOOTSTRAP_DIR}:/bootstrap/ldif:ro" \
  ${IMAGE_NAME}

for i in {1..30}; do
  if docker exec ${BOOTSTRAP_CONTAINER} /usr/local/bin/healthcheck.sh 2>/dev/null; then
    echo "✓ Bootstrap container is healthy"
    break
  fi
  if [ $i -eq 30 ]; then
    echo "✗ Bootstrap container failed to become healthy"
    docker logs ${BOOTSTRAP_CONTAINER}
    exit 1
  fi
  echo -n "."
  sleep 1
done

echo ""
echo "=== Verifying LDIF user exists ==="
if docker exec ${BOOTSTRAP_CONTAINER} ldapsearch -x -LLL \
  -D "cn=admin,dc=example,dc=com" \
  -w admin123 \
  -b "uid=john,ou=people,dc=example,dc=com" \
  "(objectClass=*)" dn; then
  echo "✓ LDIF user present"
else
  echo "✗ LDIF user not found"
  exit 1
fi

echo ""
echo "=== Verifying LDIF group membership ==="
LDIF_GROUP_RESULT=$(docker exec ${BOOTSTRAP_CONTAINER} ldapsearch -x -LLL \
  -D "cn=admin,dc=example,dc=com" \
  -w admin123 \
  -b "cn=developers,ou=groups,dc=example,dc=com" \
  "(objectClass=*)" member 2>/dev/null)
if echo "${LDIF_GROUP_RESULT}" | grep -q "uid=john,ou=people,dc=example,dc=com"; then
  echo "✓ LDIF group contains john"
else
  echo "✗ LDIF group missing john"
  echo "${LDIF_GROUP_RESULT}"
  exit 1
fi

docker rm -f ${BOOTSTRAP_CONTAINER} >/dev/null 2>&1 || true

echo ""
echo "=== Testing TLS (without certs - should work on ldap://) ==="
if docker exec ${CONTAINER_NAME} ldapsearch -x -LLL \
  -H ldap://localhost:389 \
  -D "cn=admin,dc=example,dc=com" \
  -w admin123 \
  -b "dc=example,dc=com" \
  "(objectClass=organization)" dn; then
  echo "✓ LDAP connection successful"
else
  echo "✗ LDAP connection failed"
  exit 1
fi

echo ""
echo "=== Checking container health ==="
if docker inspect --format='{{.State.Health.Status}}' ${CONTAINER_NAME} | grep -q "healthy"; then
  echo "✓ Container is healthy"
else
  echo "⚠ Container health status:"
  docker inspect --format='{{.State.Health.Status}}' ${CONTAINER_NAME}
fi

echo ""
echo "=== TLS smoke test (self-signed cert) ==="
TLS_TMP_DIR="$(generate_tls_materials)"

docker stop ${TLS_CONTAINER_NAME} 2>/dev/null || true
docker rm -v ${TLS_CONTAINER_NAME} 2>/dev/null || true

echo ""
echo "=== Starting TLS-enabled container ==="
docker run -d --name ${TLS_CONTAINER_NAME} \
  -e LDAP_DOMAIN=example.com \
  -e LDAP_ORGANIZATION="Test Org" \
  -e LDAP_ADMIN_PASSWORD=admin123 \
  -e LDAP_ENABLE_MEMBEROF=true \
  -e LDAP_TLS_ENABLED=true \
  -e LDAP_REQUIRE_TLS=false \
  -v "${TLS_TMP_DIR}/server.crt:/run/secrets/ldap/server.crt:ro" \
  -v "${TLS_TMP_DIR}/server.key:/run/secrets/ldap/server.key:ro" \
  -v "${TLS_TMP_DIR}/ca.crt:/run/secrets/ldap/ca.crt:ro" \
  ${IMAGE_NAME}

echo ""
echo "=== Waiting for TLS container startup ==="
sleep 8
docker logs ${TLS_CONTAINER_NAME}

echo ""
echo "=== Waiting for TLS container healthy status ==="
for i in {1..30}; do
  if docker exec ${TLS_CONTAINER_NAME} /usr/local/bin/healthcheck.sh 2>/dev/null; then
    echo "✓ TLS container is healthy"
    break
  fi
  if [ $i -eq 30 ]; then
    echo "✗ TLS container failed to become healthy"
    docker logs ${TLS_CONTAINER_NAME}
    exit 1
  fi
  echo -n "."
  sleep 1
done

echo ""
echo "=== Testing LDAPS (port 636) ==="
if docker exec ${TLS_CONTAINER_NAME} \
  env LDAPTLS_CACERT=/run/secrets/ldap/ca.crt LDAPTLS_REQCERT=allow \
  ldapsearch -x -LLL -H ldaps://localhost:636 \
  -D "cn=admin,dc=example,dc=com" \
  -w admin123 \
  -b "dc=example,dc=com" \
  "(objectClass=organization)" dn; then
  echo "✓ LDAPS query successful"
else
  echo "✗ LDAPS query failed"
  exit 1
fi

echo ""
echo "=== Testing StartTLS (ldap:// + -ZZ) ==="
if docker exec ${TLS_CONTAINER_NAME} \
  env LDAPTLS_CACERT=/run/secrets/ldap/ca.crt LDAPTLS_REQCERT=allow \
  ldapsearch -x -LLL -ZZ -H ldap://localhost:389 \
  -D "cn=admin,dc=example,dc=com" \
  -w admin123 \
  -b "dc=example,dc=com" \
  "(objectClass=organization)" dn; then
  echo "✓ StartTLS query successful"
else
  echo "✗ StartTLS query failed"
  exit 1
fi

echo ""
echo "=== Cleaning up TLS container ==="
docker rm -f ${TLS_CONTAINER_NAME} >/dev/null 2>&1 || true
if [[ -d "${TLS_TMP_DIR}" ]]; then
  rm -rf "${TLS_TMP_DIR}" || true
fi
TLS_TMP_DIR=""

echo ""
echo "=== TLS required mode (LDAP_REQUIRE_TLS=true) ==="
TLS_TMP_DIR="$(generate_tls_materials)"

docker stop ${TLS_REQUIRE_CONTAINER} 2>/dev/null || true
docker rm -v ${TLS_REQUIRE_CONTAINER} 2>/dev/null || true

docker run -d --name ${TLS_REQUIRE_CONTAINER} \
  -e LDAP_DOMAIN=example.com \
  -e LDAP_ORGANIZATION="Test Org" \
  -e LDAP_ADMIN_PASSWORD=admin123 \
  -e LDAP_ENABLE_MEMBEROF=true \
  -e LDAP_TLS_ENABLED=true \
  -e LDAP_REQUIRE_TLS=true \
  -v "${TLS_TMP_DIR}/server.crt:/run/secrets/ldap/server.crt:ro" \
  -v "${TLS_TMP_DIR}/server.key:/run/secrets/ldap/server.key:ro" \
  -v "${TLS_TMP_DIR}/ca.crt:/run/secrets/ldap/ca.crt:ro" \
  ${IMAGE_NAME}

echo ""
echo "=== Waiting for TLS-required container startup ==="
sleep 8
docker logs ${TLS_REQUIRE_CONTAINER}

echo ""
echo "=== Plain LDAP should be rejected when TLS is required ==="
if docker exec ${TLS_REQUIRE_CONTAINER} \
  ldapsearch -x -LLL -H ldap://localhost:389 \
  -D "cn=admin,dc=example,dc=com" \
  -w admin123 \
  -b "dc=example,dc=com" \
  "(objectClass=organization)" dn; then
  echo "✗ Plain LDAP unexpectedly succeeded while TLS required"
  exit 1
else
  echo "✓ Plain LDAP is blocked as expected"
fi

echo ""
echo "=== StartTLS should negotiate successfully when TLS required ==="
if docker exec ${TLS_REQUIRE_CONTAINER} \
  env LDAPTLS_CACERT=/run/secrets/ldap/ca.crt LDAPTLS_REQCERT=allow \
  ldapsearch -x -LLL -ZZ -H ldap://localhost:389 \
  -D "cn=admin,dc=example,dc=com" \
  -w admin123 \
  -b "dc=example,dc=com" \
  "(objectClass=organization)" dn; then
  echo "✓ StartTLS succeeded under TLS-required mode"
else
  echo "✗ StartTLS failed under TLS-required mode"
  exit 1
fi

echo ""
echo "=== Cleaning up TLS-required container ==="
docker rm -f ${TLS_REQUIRE_CONTAINER} >/dev/null 2>&1 || true
if [[ -d "${TLS_TMP_DIR}" ]]; then
  rm -rf "${TLS_TMP_DIR}" || true
fi
TLS_TMP_DIR=""

echo ""
echo "=== TLS enabled without certs should fail ==="
if docker run --rm --name ${TLS_FAIL_CONTAINER} \
  -e LDAP_DOMAIN=example.com \
  -e LDAP_ORGANIZATION="Test Org" \
  -e LDAP_ADMIN_PASSWORD=admin123 \
  -e LDAP_ENABLE_MEMBEROF=true \
  -e LDAP_TLS_ENABLED=true \
  ${IMAGE_NAME}; then
  echo "✗ TLS container without certs unexpectedly started"
  exit 1
else
  echo "✓ TLS start without certs failed as expected"
fi

echo ""
echo "=== Final logs ==="
docker logs ${CONTAINER_NAME} | tail -20

echo ""
echo "======================================"
echo "✅ All tests passed!"
echo "======================================"
echo ""
