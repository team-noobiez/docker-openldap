# noobiez/openldap

[English](README.md) | [한국어](README.ko.md)

이 저장소는 다음과 같은 기능이 반영된 최소 구성 OpenLDAP 컨테이너 이미지를 제공합니다.
- 첫 실행 시 `/etc/ldap/slapd.d` 아래에 `cn=config`를 생성합니다.
- 기본 DN과 `ou=people` / `ou=groups` 조직 단위를 자동으로 만듭니다.
- `/bootstrap/ldif/*.ldif`(예: `image/bootstrap/ldif/10-sample-group.ldif`)에 놓인 추가 LDIF를 적용합니다.
- osixia 이미지와 호환되는 readonly 바인드 사용자 + ACL을 내장합니다.
- 마운트한 인증서/키로 TLS를 `auto|true|false` 모드로 구성하며 `LDAP_REQUIRE_TLS` 강제 옵션을 지원합니다.
- `image/test.sh` 통합 테스트 스크립트로 위 기능(memberOf 오버레이, readonly ACL, bootstrap LDIF, TLS auto/require/실패)을 검증할 수 있습니다.

## 목차

- [빠른 시작](#빠른-시작)
- [환경 변수](#환경-변수)
- [보안 고려 사항](#보안-고려-사항)
- [Bootstrap LDIF](#bootstrap-ldif)
- [테스트](#테스트)
- [로드맵](#로드맵-next-steps)

## 빠른 시작

```bash
cd example
docker compose up --build -d
```

테스트:

```bash
docker exec -it openldap \
  ldapsearch -x -H ldap://localhost:389 \
  -D "cn=admin,dc=example,dc=com" \
  -w change-me-now \
  -b "dc=example,dc=com" dn
```

## 환경 변수

필수:
- `LDAP_DOMAIN` (예: `example.com`)
- `LDAP_ADMIN_PASSWORD` 또는 `LDAP_ADMIN_PASSWORD_FILE`

선택:
- `LDAP_BASE_DN` (기본값: `LDAP_DOMAIN`에서 자동 계산)
- `LDAP_ORGANIZATION` (기본값: `Example Org`)
- `LDAP_BOOTSTRAP_LDIF_DIR` (기본값: `/bootstrap/ldif`)
- `LDAP_TLS_ENABLED` = `auto|true|false` (기본값: `auto`)
- `LDAP_TLS_CRT_FILE`, `LDAP_TLS_KEY_FILE`, `LDAP_TLS_CA_FILE`
- `LDAP_REQUIRE_TLS` = `true|false` (기본값: `false`)

## 보안 고려 사항

### 기본 ACL

이 이미지는 기본적으로 다소 완화된 ACL을 구성합니다. `access to * by users read` 규칙에 따라 인증된 모든 사용자는 디렉토리 내 대부분의 데이터를 읽을 수 있습니다. 이는 일반적인 용도에는 적합하지만, 민감한 정보를 포함하는 환경에서는 보안상 취약할 수 있습니다.

더 엄격한 접근 제어가 필요한 경우, 커스텀 LDIF 파일을 마운트하여 데이터베이스 설정 `olcDatabase={1}mdb,cn=config`의 `olcAccess` 속성을 수정하시기 바랍니다.

## Bootstrap LDIF

사용자 정의 LDIF 파일을 `./bootstrap/ldif/*.ldif` 경로에 마운트하십시오. 이 파일들은 Base DN이 생성된 후 사전순으로 적용됩니다.

## 테스트

도커가 설치된 환경에서 통합 테스트 스크립트를 실행할 수 있습니다.

```bash
cd image
bash test.sh
```

이 스크립트는 이미지를 빌드하고 다음 시나리오들을 실행합니다:
- 컨테이너 헬스 체크 + `memberOf` 오버레이 + 읽기 전용 사용자 ACL 검증
- 부트스트랩 LDIF 적용 확인 (`bootstrap/ldif`의 `uid=john,...` 존재 여부)
- TLS 자동 모드 (자체 서명 인증서) 테스트 (`ldaps://` 및 `StartTLS`)
- TLS 강제 모드 (`LDAP_REQUIRE_TLS=true`) 시 일반 LDAP 바인드 거부 확인
- 인증서 없는 TLS 활성화 시 실패 케이스 검증

테스트 종료 시 사용된 헬퍼 컨테이너들은 자동으로 삭제됩니다.

GitHub Actions(`.github/workflows/ci.yml`) 으로 모든 push / PR 이벤트마다 동일한 시나리오를 실행합니다. 이미지를 한 번 빌드해 아티팩트로 저장한 뒤, 각 잡이 이를 불러 스모크, readonly ACL, memberOf, bootstrap LDIF, TLS 자동/강제/실패 케이스를 검증합니다.

## 로드맵 (next steps)

- 더 많은 비밀 정보(바인드 사용자, 복제 자격 증명 등)에 대해 `_FILE` 방식 지원
- 오버레이 토글 기능 (`memberof`, `ppolicy`, `syncprov`)
- `slapcat` 을 이용한 예약 백업 기능
- Kubernetes 매니페스트 및 Helm 차트 제공
