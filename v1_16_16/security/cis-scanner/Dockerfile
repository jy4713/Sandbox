# syntax=docker/dockerfile:1.7
# =============================================================================
# PACKAGE MAINTENANCE NOTES
# Purpose: Builds the Admin-only OpenSCAP scanner image from pinned ComplianceAsCode content.
# Admin maintenance: Application changes do not belong here. Modify only when the scanner toolchain or pinned compliance content workflow changes.
# Safety rule: preserve secret-free images/configuration, immutable version or
# digest pinning where applicable, and update the paired Bash/PowerShell path.
# After any change, run scripts/ci/lint-package.* and the applicable build/QA.
# Full change procedure: docs/ADMIN-COMPLETE-GUIDE.md
# =============================================================================
# Admin-only OpenSCAP scanner. Not distributed to developers.
ARG BASE_IMAGE
FROM ${BASE_IMAGE}
ARG SSG_URL
ARG SSG_SHA256
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN [[ "${SSG_URL}" == https://* ]] \
    && [[ "${SSG_SHA256}" =~ ^[0-9a-fA-F]{64}$ ]] \
    || { echo "ERROR: SSG_URL/SSG_SHA256 not set correctly"; exit 1; }
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl openscap-scanner openscap-utils unzip \
    && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL --proto '=https' --tlsv1.2 "${SSG_URL}" -o /tmp/ssg.zip \
    && printf '%s  %s\n' "${SSG_SHA256}" /tmp/ssg.zip | sha256sum --check --strict - \
    && mkdir -p /opt/ssg-src /opt/ssg \
    && unzip -q /tmp/ssg.zip -d /opt/ssg-src \
    && ds="$(find /opt/ssg-src -type f -name 'ssg-ubuntu2404-ds.xml' -print -quit)" \
    && test -n "$ds" \
    && install -m 0444 "$ds" /opt/ssg/ssg-ubuntu2404-ds.xml \
    && rm -rf /tmp/ssg.zip /opt/ssg-src \
    && oscap --version
ENTRYPOINT ["oscap"]
