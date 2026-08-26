# syntax=docker/dockerfile:1.7
# =============================================================================
# PACKAGE MAINTENANCE NOTES
# Purpose: Builds the hardened Squid proxy used as the only approved web egress path for the devcontainer.
# Admin maintenance: New applications normally require only whitelist.txt changes. Modify this Dockerfile only if Squid itself needs packages, certificates, or proxy behavior changes.
# Safety rule: preserve secret-free images/configuration, immutable version or
# digest pinning where applicable, and update the paired Bash/PowerShell path.
# After any change, run scripts/ci/lint-package.* and the applicable build/QA.
# Full change procedure: docs/ADMIN-COMPLETE-GUIDE.md
# =============================================================================
# =============================================================================
# Squid egress proxy — hardened
# Build:  docker build -f squid/Dockerfile --build-arg BASE_IMAGE=... squid/
# =============================================================================
ARG BASE_IMAGE=ubuntu:24.04
FROM ${BASE_IMAGE}

ARG BUILD_DATE

LABEL org.opencontainers.image.title="AI Sandbox Squid egress proxy" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      hardening="default-deny, IP block, DoH block, CONNECT 443, cache_mem 64MB"

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends squid squidclient \
    && rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/* \
    && find /usr/share/doc -type f ! -name copyright -delete 2>/dev/null || true \
    && rm -rf /usr/share/man/* /usr/share/locale/* 2>/dev/null || true

COPY whitelist.txt /etc/squid/whitelist.txt
COPY squid.conf    /etc/squid/squid.conf

RUN chown -R proxy:proxy /var/log/squid /var/spool/squid \
    && chmod 0750 /var/log/squid /var/spool/squid \
    && chmod 0644 /etc/squid/squid.conf /etc/squid/whitelist.txt \
    && squid -k parse -f /etc/squid/squid.conf \
    && find / -xdev -type f -perm /6000 -exec chmod a-s {} + 2>/dev/null || true

USER proxy
EXPOSE 3128

# [FIX] mgr:ping is not a valid squidclient action — use mgr:info instead.
# manager_urlpath acl in squid.conf only allows requests from 127.0.0.1/::1,
# so this must run from inside the container (which healthcheck does).
HEALTHCHECK --interval=30s --timeout=10s --start-period=15s --retries=3 \
    CMD squidclient -h 127.0.0.1 -p 3128 mgr:info || exit 1

CMD ["squid", "-N", "-f", "/etc/squid/squid.conf"]
