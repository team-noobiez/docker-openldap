# syntax=docker/dockerfile:1
#
# SPDX-FileCopyrightText: © Team Noobiez
# SPDX-License-Identifier: Apache-2.0 or MIT
# SPDX-ArtifactOfProjectHomePage: https://github.com/team-noobiez/docker-openldap
#
# References:
# - https://www.openldap.org/doc/admin26/
# - https://hub.docker.com/_/debian/tags?name=trixie-slim
# - https://docs.docker.com/engine/reference/builder/
FROM debian:trixie-slim

ARG DEBIAN_FRONTEND=noninteractive
ARG BUILD_DATE
ARG VCS_REF

LABEL org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.source="https://github.com/team-noobiez/docker-openldap"

# Prevent services from starting during package install
RUN printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d && chmod +x /usr/sbin/policy-rc.d

RUN apt-get update && apt-get install -y --no-install-recommends \
    slapd ldap-utils openssl ca-certificates tini bash coreutils findutils \
  && rm -rf /var/lib/apt/lists/*

# Clean default slapd config from package installation
RUN rm -rf /etc/ldap/slapd.d/*

# Runtime dirs
RUN mkdir -p /var/run/slapd /bootstrap/ldif /docker-entrypoint.d \
 && chown -R openldap:openldap /var/run/slapd /bootstrap /etc/ldap/slapd.d /var/lib/ldap

COPY docker-entrypoint.sh /docker-entrypoint.sh
COPY docker-entrypoint.d/ /docker-entrypoint.d/

RUN chmod +x /docker-entrypoint.sh /docker-entrypoint.d/*.sh

EXPOSE 389 636

VOLUME ["/var/lib/ldap", "/etc/ldap/slapd.d", "/backup"]

COPY healthcheck.sh /usr/local/bin/healthcheck.sh
RUN chmod +x /usr/local/bin/healthcheck.sh

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD /usr/local/bin/healthcheck.sh

ENTRYPOINT ["/usr/bin/tini","--","/docker-entrypoint.sh"]
CMD []
