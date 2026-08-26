# AI Secure Sandbox v1.16.16 — Complete Package, Build, Runtime and Maintenance Guide

> **Document status:** This is the authoritative detailed operational guide for the v1.16.16 Admin package. The active build package intentionally excludes release-history, package-cleanup, language-audit, and QA-evidence files. Those records belong in source control, release storage, change management, or an external evidence repository when required. The `docs/` directory is documentation-only and is not a build, export, deploy, or lint dependency.

## 1. What this package is

AI Secure Sandbox v1.16.16 is an Admin-built, two-container development environment for Windows 365 and Docker Desktop. The Admin validates and pins external build inputs, creates a hardened Ubuntu 24.04 base, builds the DevContainer and Squid proxy, assesses the final DevContainer with OpenSCAP, and then distributes either POC TAR images or Production ECR digests.

The Developer runtime consists of two containers:

```text
Windows 365 host
  |
  +-- Docker Desktop
  |     |
  |     +-- DevContainer
  |     |     - internal Docker network only
  |     |     - non-root vscode user
  |     |     - read-only root filesystem
  |     |     - approved AI/CLI tools
  |     |     - SSM-aware command wrappers
  |     |     - Claude/Gemini/MCP runtime controls
  |     |
  |     `-- Squid proxy
  |           - internal + external Docker networks
  |           - default-deny outbound policy
  |           - approved destination allowlist
  |
  +-- Windows browser
  |     `-- AWS auth: static Access Key/Secret Key first, IAM Identity Center SSO/MFA fallback
  |
  `-- Host log directory
        `-- AMA/DCR or Logs Ingestion API -> Sentinel
```

The most important security boundaries are:

- The Developer container does not receive the Docker socket.
- The DevContainer root filesystem is read-only at runtime.
- Linux capabilities are dropped and `no-new-privileges` is enabled.
- Developers work as the non-root `vscode` user.
- Approved vendor executables and security wrappers are baked into the image.
- Long-lived application secrets are not stored in image layers, `.env`, the workspace, or MCP configuration. The only supported `.env` secret exception is the optional AWS bootstrap Access Key/Secret Key pair when SSO cannot be used.
- AWS authentication priority is static runtime Access Key/Secret Key first, then IAM Identity Center SSO fallback. Wrappers fetch only the required SSM parameter and inject it into the application child process.
- The DevContainer has no direct external Docker network. External traffic must traverse Squid.
- DevContainer and Squid logs are exported to host bind mounts. Sentinel forwarding is a host responsibility, not a container responsibility.

---

# Part A — Package structure and configuration ownership

## 2. Top-level layout

```text
AI_Sandbox_Admin_v1_16_4_...
|-- README.md
|-- .build.env.example
|-- .env.example
|-- .dockerignore
|-- .devcontainer/
|-- ado-scripts/
|-- docs/                    # optional human-readable Admin documentation only
|-- ecr/
|-- poc/
|-- policies/
|-- scripts/
|-- security/
|-- sentinel/
|-- squid/
|-- templates/               # active Developer package generation inputs
|   `-- developer/
`-- workspace/
```

`README.md` is the short entry point. `docs/ADMIN-COMPLETE-GUIDE.md`, `docs/ADMIN-APPLICATION-ADD-REMOVE.md`, and `docs/SECURITY-LOGGING-AND-SENTINEL.md` are optional operational references. They are not required by the image build, Developer package export, direct Production deployment, or package lint. The files under `templates/developer/` are different: they are active package-generation inputs and therefore are linted and must remain present.

The repository-root `.dockerignore` is authoritative because the DevContainer Docker build context is the repository root. Nested `.dockerignore` files do not control that build context.

## 3. `.build.env.example` — Admin build inputs

`.build.env.example` defines build-time, non-secret, release-controlled inputs. `scripts/admin/build-sandbox.*` copies it to `.build.env` when `.build.env` does not already exist.

Major groups are:

```text
Release identity
  SANDBOX_VERSION
  RELEASE_TAG
  DEVCONTAINER_TARGET

Base images
  BASE_IMAGE
  NODE_IMAGE
  SQUID_BASE_IMAGE

Approved tool versions and sources
  CLAUDE_CODE_VERSION
  GEMINI_CLI_VERSION
  TAVILY_CLI_VERSION
  TAVILY_MCP_VERSION
  SNYK_CLI_VERSION
  AWSCLI_URL / AWSCLI_SHA256
  DATABRICKS_CLI_VERSION / URL / SHA256
  UCODE_GIT_REF
  GCM_VERSION / GCM_SHA256

OpenSCAP / ComplianceAsCode
  SSG_VERSION
  SSG_URL
  SSG_SHA256
  CIS_PROFILE_ID
  REQUIRE_CIS_PASS

Production controls
  MAX_CRITICAL_FINDINGS
  MAX_HIGH_FINDINGS
  REQUIRE_IMAGE_SIGNING
  COSIGN_KEY_REF
  PUBLISH_APPROVED_MANIFEST_TO_SSM
  SSM_PREFIX
  APPROVED_IMAGES_SSM_PARAMETER

Developer SSO fallback defaults
  DEVELOPER_AWS_PROFILE
  DEVELOPER_AWS_REGION
  DEVELOPER_AWS_SSO_SESSION
  DEVELOPER_AWS_SSO_START_URL
  DEVELOPER_AWS_SSO_REGION
  DEVELOPER_AWS_SSO_ACCOUNT_ID
  DEVELOPER_AWS_SSO_ROLE_NAME
```

Rules for `.build.env`:

1. It is not a secret store.
2. Base images should end up pinned as immutable `repository@sha256:...` references.
3. `BASE_IMAGE` and `SQUID_BASE_IMAGE` are replaced with the same hardened-base digest after the hardened-base build.
4. Directly downloaded artifacts must use immutable version/source information and approved SHA-256 values where supported.
5. `UCODE_GIT_REF` is resolved to an immutable 40-character Git commit.
6. Application additions may require coordinated changes to `.build.env.example`, the build-env parser, Docker build arguments, and the Dockerfile.
7. Developer SSO fallback values are non-secret routing metadata. They may be stamped into Developer packages, but they are required only when the runtime `.env` does not provide both `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`.

## 4. `.env.example` — runtime configuration and AWS authentication bootstrap

`.env.example` is the runtime configuration template used by POC and Production Developer launchers. Most values are non-secret. The explicit exception is an optional AWS bootstrap key pair (`AWS_ACCESS_KEY_ID` + `AWS_SECRET_ACCESS_KEY`, plus optional `AWS_SESSION_TOKEN`) when IAM Identity Center cannot be used.

Important values include:

```text
DATABRICKS_HOST
DATABRICKS_CLAUDE_MODEL
DATABRICKS_GEMINI_MODEL

SANDBOX_AWS_PROFILE
AWS_REGION
SSM_PREFIX
AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY
AWS_SESSION_TOKEN
AWS_SSO_SESSION
AWS_SSO_START_URL
AWS_SSO_REGION
AWS_SSO_ACCOUNT_ID
AWS_SSO_ROLE_NAME

DEVELOPER_ID
SANDBOX_AUDIT_REQUIRED
SNYK_API
HIDDENLAYER_API_URL
SANDBOX_LOG_ROOT
APPROVED_IMAGES_SSM_PARAMETER
```

Do not put application credentials such as Databricks tokens, ADO PATs, Tavily keys, Snyk tokens, HiddenLayer secrets, passwords, or SSO tokens in `.env`. The only supported secret exception is the approved AWS bootstrap Access Key/Secret Key pair when SSO is unavailable. In that mode `.env` must be treated as a local secret file and must never be committed or baked into an image.

Runtime application secrets are obtained from AWS Systems Manager Parameter Store when an approved command executes.

---

# Part B — Admin build orchestration

> **Windows shell requirement:** all `.ps1` entry points in this baseline require PowerShell 7.4+ (`pwsh`). Windows PowerShell 5.1 is not a supported host for this package.

## 5. Primary Admin entry point

The supported orchestration entry point is:

```powershell
.\scripts\admin\build-sandbox.ps1 -SandboxType POC
```

or for Production:

```powershell
.\scripts\admin\build-sandbox.ps1 -SandboxType Production
```

The Bash peer is `scripts/admin/build-sandbox.sh`.

The orchestration script intentionally remains thin. It selects the hardening and distribution path and delegates detailed work to supply-chain, hardening, POC, ECR, and security scripts.

Before the first build, the Admin normally performs:

```powershell
Copy-Item .build.env.example .build.env
.\scripts\ci\lint-package.ps1
```

The build script also creates `.build.env` automatically if it is missing, but explicit creation is useful because the Admin can review and populate organization-specific values before the first release.

### 5.1 Fast iterative builds with `-ReuseHardenedBase`

v1.16.16 adds an explicit hardened-base reuse mode for repeated POC or Production image builds where the OS hardening baseline has not changed. This is useful when testing DevContainer scripts, application wrappers, Dockerfile application layers, Squid configuration, logging, or other changes above the hardened OS layer.

The safest workflow is to copy the previously resolved `.build.env` from the last successful build into the new v1.16.16 Admin package and then request reuse:

```powershell
Copy-Item 'C:\path\to\previous-package\.build.env' .\.build.env
.\scripts\admin\build-sandbox.ps1 -SandboxType POC -ReuseHardenedBase
```

The same operation can be done in one command:

```powershell
pwsh -NoProfile -File .\scripts\admin\build-sandbox.ps1 `
  -SandboxType POC `
  -ReuseHardenedBase `
  -BuildEnvSource 'C:\path\to\previous-package\.build.env'
```

Bash equivalent:

```bash
bash scripts/admin/build-sandbox.sh POC \
  --reuse-hardened-base \
  --build-env-source ../previous-package/.build.env
```

Reuse is **never assumed**. The Admin entry point performs all of these checks before skipping hardening:

1. `.build.env` exists.
2. Every normally required build value is present, resolved, correctly formatted, and digest-pinned.
3. `BASE_IMAGE` and `SQUID_BASE_IMAGE` are exactly the same reference.
4. The exact hardened digest can be inspected locally or pulled successfully.
5. The image label `hardening.method` matches the requested SandboxType (`poc` for POC, `production` for non-POC builds).
6. The image label `hardening.profile` is `cis_level1_server`.

If any check fails, the script prints the reuse failure reason and automatically returns to the standard workflow:

```text
resolve base/tool inputs
  -> rebuild hardened base
  -> update BASE_IMAGE/SQUID_BASE_IMAGE
  -> build DevContainer/Squid
```

This means `-ReuseHardenedBase` is an optimization request, not a command to bypass validation. An incomplete copied `.build.env`, a deleted hardened image, a stopped/unavailable scratch-registry digest, a wrong hardening mode, or an invalid label causes a normal rebuild instead of a partially trusted reuse.

When a previous `.build.env` is copied, the Admin entry point updates `SANDBOX_VERSION` to `v1.16.16`. If `RELEASE_TAG` still equals the previous package version, it is updated to `v1.16.16` as well; an intentionally custom release tag is preserved.

For Production, a valid reused Production hardened base does not require the Ubuntu Pro token again. If reuse validation fails and a new Production hardened base is required, the Ubuntu Pro token becomes mandatory as in the normal build path.

Without `-ReuseHardenedBase`, behavior is unchanged: the hardened base is rebuilt.

## 6. POC build call graph

The POC path is:

```text
scripts/admin/build-sandbox.ps1 -SandboxType POC
  |
  |-- [0] Ensure .build.env exists and stamp v1.16.16
  |
  |-- [reuse requested?] Validate complete .build.env + exact labelled hardened digest
  |      |-- PASS -> skip [1]-[4] and continue to final runtime-image build
  |      `-- FAIL -> automatically run the normal full path below
  |
  |-- [1] scripts/supply-chain/resolve-base-digests.ps1 -Write
  |      |-- resolve Ubuntu base digest
  |      |-- resolve Node image digest
  |      `-- update .build.env
  |
  |-- [2] scripts/supply-chain/resolve-tool-artifacts.ps1 -Write
  |      |-- resolve AWS CLI SHA-256
  |      |-- resolve Databricks CLI SHA-256
  |      |-- resolve ComplianceAsCode/SSG SHA-256
  |      |-- resolve GCM hash when configured
  |      |-- resolve ucode Git reference to immutable commit
  |      `-- update .build.env
  |
  |-- [3] scripts/hardening/build-hardened-base.ps1 -SandboxType POC
  |      |-- load and validate .build.env
  |      |-- obtain pinned SSG content
  |      |-- create temporary hardening build context
  |      |-- build candidate Ubuntu base
  |      |-- run OpenSCAP assessment/remediation workflow
  |      |-- remove hardening-only tooling from final base
  |      |-- publish through the configured scratch/local registry path when needed
  |      |-- obtain immutable hardened image digest
  |      `-- write hardened-base-build/hardened-base.env
  |
  |-- [4] Apply-HardenedBaseEnvironment
  |      |-- read hardened-base.env
  |      |-- set BASE_IMAGE to hardened digest
  |      `-- set SQUID_BASE_IMAGE to the same hardened digest
  |
  `-- [5] scripts/poc/build-and-export.ps1
         |-- load/validate .build.env
         |-- build final DevContainer
         |-- assess final DevContainer with separate OpenSCAP scanner image
         |-- copy security evidence
         |-- build Squid from the same hardened base digest
         |-- docker save both images
         |-- capture immutable Docker image IDs
         |-- create image-manifest.env
         |-- create image-manifest.json
         |-- create runtime-policy.sha256
         `-- create SHA256SUMS
```

### POC outputs

The main POC release artifacts are written beneath `poc/images/`:

```text
poc/images/
|-- sandbox-devcontainer.tar
|-- sandbox-squid.tar
|-- image-manifest.env
|-- image-manifest.json
|-- runtime-policy.sha256
|-- SHA256SUMS
`-- security/
    `-- OpenSCAP/CIS assessment evidence
```

After a successful POC image build, the Admin creates the distributable Developer package with:

```powershell
.\scripts\admin\export-developer-packages.ps1 -IncludePocImages
```

The POC Developer package must contain v1.16.16 images. Do not reuse older v1.16.3 TAR images because this v1.16.16 baseline adds dual-mode AWS authentication helpers (static-key priority with browser SSO fallback) and `sandbox-info` inside the DevContainer image.

## 7. Production build call graph

The Production path begins with the same supply-chain resolution steps and then switches to Ubuntu Pro/USG hardening and ECR publication:

```text
scripts/admin/build-sandbox.ps1 -SandboxType Production
  |
  |-- ensure .build.env exists and stamp v1.16.16
  |-- if -ReuseHardenedBase: validate complete .build.env + exact Production hardened digest
  |      |-- PASS -> skip resolver/hardening and continue to ECR final-image build
  |      `-- FAIL -> automatically continue with full Production hardening path
  |-- resolve base image digests
  |-- resolve tool hashes and ucode commit
  |
  |-- scripts/hardening/build-hardened-base.ps1
  |      |-- Ubuntu Pro token supplied as BuildKit secret
  |      |-- Ubuntu Pro / USG hardening
  |      |-- hardening evidence
  |      |-- removal of build-only hardening tooling
  |      `-- hardened-base-build/hardened-base.env
  |
  |-- update BASE_IMAGE and SQUID_BASE_IMAGE
  |-- force REQUIRE_CIS_PASS=true
  |
  `-- scripts/platform/02-setup-ecr.ps1
         |-- ensure ECR repositories/policies
         |-- build final DevContainer
         |-- run final-image CIS/OpenSCAP gate
         |-- build Squid
         |-- push images to ECR
         |-- obtain immutable ECR digests
         |-- create approved-images manifest
         `-- optionally publish approved manifest to SSM
```

Production Developers do not receive Docker build inputs. Their launcher resolves the centrally approved image manifest, pulls exact ECR digests, tags them to local approved runtime names, and starts Compose with `pull_policy: never`.

---

# Part C — Supply-chain resolution

## 8. `scripts/supply-chain/resolve-base-digests.*`

Purpose: convert mutable upstream base references into immutable digest-pinned references before image construction.

The resolver updates values such as:

```text
BASE_IMAGE=ubuntu:24.04@sha256:<resolved digest>
NODE_IMAGE=node:20-bookworm-slim@sha256:<resolved digest>
SQUID_BASE_IMAGE=ubuntu:24.04@sha256:<resolved digest>
```

The hardened-base stage later replaces both runtime base references with the immutable digest of the internally hardened base.

## 9. `scripts/supply-chain/resolve-tool-artifacts.*`

Purpose: resolve or validate immutable artifact metadata used by the Docker build.

Typical responsibilities:

- AWS CLI archive SHA-256.
- Databricks CLI release SHA-256.
- ComplianceAsCode/SSG archive SHA-256.
- Git Credential Manager hash when configured.
- `UCODE_GIT_REF` normalization to an immutable Git commit.

This keeps network-dependent discovery in an Admin-controlled pre-build step rather than hiding mutable downloads inside runtime initialization.

## 10. `scripts/common/Load-BuildEnv.ps1` and `load-build-env.sh`

These are shared parsers for `.build.env`. They read the file as data rather than executing it as arbitrary shell/PowerShell code, validate required values, and expose the resulting build configuration to downstream scripts.

When a new required build variable is added, both implementations must remain synchronized.

---

# Part D — Hardened base creation

## 11. `scripts/hardening/build-hardened-base.*`

The hardened-base builder is deliberately separate from the final DevContainer Dockerfile. The goal is to establish a reusable security baseline and then layer application/runtime content on top.

### POC mode

POC uses a self-hardening workflow based on Ubuntu 24.04 and OpenSCAP/ComplianceAsCode content. It is designed to produce repeatable hardening evidence without requiring the Production Ubuntu Pro entitlement path.

Conceptually:

```text
Pinned Ubuntu base
  -> hardening build context
  -> OpenSCAP/SSG content
  -> candidate base
  -> assessment/remediation
  -> remove hardening-only toolchain
  -> immutable hardened base digest
```

### Production mode

Production uses Ubuntu Pro and USG. The Ubuntu Pro token is treated as a build secret rather than a normal Docker build argument so it is not intentionally persisted in image metadata or layers.

Conceptually:

```text
Pinned Ubuntu base
  -> Ubuntu Pro attach during build
  -> USG/CIS hardening
  -> evidence
  -> detach/cleanup as required by implementation
  -> remove hardening-only tooling
  -> immutable hardened base digest
```

### Scratch/local registry rationale

A local or scratch registry may be used during the build to convert an internally created image into a stable digest reference that subsequent Dockerfiles can consume with `FROM repository@sha256:...`. This is a build-time mechanism; it is not the Production distribution boundary. POC distribution is TAR export and Production distribution is ECR.

### `hardened-base-build/hardened-base.env`

The builder writes:

```text
BASE_IMAGE=<hardened repository@sha256:digest>
SQUID_BASE_IMAGE=<same hardened repository@sha256:digest>
```

`build-sandbox.*` copies only these two values back into `.build.env`, ensuring the DevContainer and Squid are based on the same approved hardened root.

---

# Part E — Why OpenSCAP appears twice

## 12. Two distinct OpenSCAP roles

OpenSCAP appears in two different phases and the distinction is important.

### Role A — hardened-base creation and evidence

The hardened-base builder uses OpenSCAP/SSG or Ubuntu Pro/USG depending on the selected build mode to produce the security baseline.

### Role B — final DevContainer assessment

After application tools, runtime wrappers, users, writable-path preparation, and other DevContainer content have been added, `scripts/security/assess-cis-l1.*` assesses the **final** DevContainer image.

This catches regressions introduced after the base was hardened. A hardened base alone is not evidence that the final application image still meets the expected security baseline.

The final assessment uses a separate scanner image rather than installing OpenSCAP into the production DevContainer. This keeps scanning tools out of the runtime image and reduces runtime attack surface.

## 13. `security/cis-scanner/Dockerfile`

This Dockerfile builds the dedicated OpenSCAP/ComplianceAsCode scanner used by the final-image assessment scripts. It is a build/assessment utility image and is not delivered as a Developer runtime service.

## 14. `security/CIS-TAILORING-README.md`

This document describes how an organization-approved tailoring file can be introduced when specific CIS controls require formally reviewed exceptions. Production should fail closed when required assessment criteria are not met.

---

# Part F — Final DevContainer build

## 15. `.devcontainer/Dockerfile`

The Dockerfile constructs the application runtime on top of the hardened base.

### 15.1 Node source stage

A digest-pinned Node image is used as a controlled source for the Node runtime rather than running an unverified remote installation script.

### 15.2 Hardened runtime stage

The final stage starts from `BASE_IMAGE`, which should already point to the immutable hardened-base digest produced earlier.

### 15.3 Build parameter validation

Required versions, URLs, hashes, and immutable references are checked early so a build fails before expensive package installation when configuration is incomplete.

### 15.4 System dependencies

Only packages required by the approved development/runtime toolchain are installed. Package changes must be reviewed as supply-chain and attack-surface changes.

### 15.5 Approved CLI and agent installation

The Dockerfile installs the approved toolset, including the configured versions of Claude Code, Gemini CLI, Tavily CLI/MCP, Snyk CLI, AWS CLI, Databricks CLI, ucode, Azure CLI, Git Credential Manager, and supporting runtimes.

Different tools use different approved installation methods. The package does not pretend that every vendor tool has the same installer. Direct archive downloads are verified with SHA-256 where implemented; npm tools use exact package versions; ucode uses an immutable Git commit.

### 15.6 Real executable stash

Vendor executables that require Admin command wrapping are preserved under:

```text
/usr/local/libexec/ai-sandbox/real/
```

The public command names point to the Admin-controlled `sandbox-command-wrapper`. This prevents Developers from accidentally bypassing the SSM/audit path by invoking the normal command name.

Typical mapping:

```text
/usr/local/bin/claude      -> sandbox-command-wrapper
/usr/local/bin/gemini      -> sandbox-command-wrapper
/usr/local/bin/tvly        -> sandbox-command-wrapper
/usr/local/bin/snyk        -> sandbox-command-wrapper
/usr/local/bin/databricks  -> sandbox-command-wrapper

/usr/local/libexec/ai-sandbox/real/claude
/usr/local/libexec/ai-sandbox/real/gemini
/usr/local/libexec/ai-sandbox/real/tvly
/usr/local/libexec/ai-sandbox/real/snyk
/usr/local/libexec/ai-sandbox/real/databricks
```

### 15.7 Non-root user and writable directories

The Dockerfile prepares the `vscode` user and only the specific home/config/cache locations required by runtime tools. The runtime root filesystem is read-only, so writable state must live in approved volume-mounted paths or tmpfs.

### 15.8 `cis-level1-harden.sh`

This is an image-level hardening script applied during DevContainer construction. It complements, rather than replaces, the separate final OpenSCAP assessment.

### 15.9 Runtime security scripts copied into the image

Key runtime programs include:

```text
/usr/local/bin/application-audit
/usr/local/bin/claude-audit-hook
/usr/local/bin/configure-aws-sso
/usr/local/bin/configure-mcp
/usr/local/bin/run-with-ssm-secrets
/usr/local/bin/sandbox-aws-login
/usr/local/bin/sandbox-info
/usr/local/bin/tavily-mcp-ssm
/usr/local/bin/snyk-mcp-ssm
/usr/local/bin/verify-runtime
/usr/local/libexec/ai-sandbox/sandbox-command-wrapper
```

### 15.10 Claude managed hook policy

The image writes the Admin-controlled Claude managed settings under:

```text
/etc/claude-code/managed-settings.json
```

This is separate from Developer-owned `~/.claude` state. The managed policy registers lifecycle/tool audit hooks while excluding prompt/response/tool payload content from the host audit stream.

### 15.11 Build information

v1.16.16 includes read-only, non-secret build provenance under:

```text
/etc/ai-sandbox/build-info.json
```

Developers can inspect effective runtime and build information through:

```bash
sandbox-info
```

### 15.12 Build targets

`DEVCONTAINER_TARGET` selects the Docker build target used by Admin build scripts. Production/POC release tooling controls the target; Developers do not choose it.

---

# Part G — Squid build and egress control

## 16. `squid/Dockerfile`

Squid is built internally from the same hardened base digest used by the DevContainer. It is not consumed as an arbitrary third-party Docker Hub proxy appliance.

The image installs the approved Ubuntu Squid package, copies the Drax-managed configuration and allowlist, and runs with restricted privileges.

## 17. `squid/squid.conf`

The Squid policy implements the controlled egress boundary. Important characteristics include:

- Default deny.
- Approved destination-domain ACLs.
- HTTPS CONNECT restriction.
- No general open-proxy host port exposure in the Compose definitions.
- Cache disabled for this security use case.
- Host-visible access logging.
- Restricted manager access.

Squid does not perform TLS payload interception in the current design. It controls destination/connection metadata. If corporate policy requires TLS inspection or DLP, that function should normally be provided by the organization-approved secure web gateway or equivalent upstream control.

## 18. `squid/whitelist.txt`

This is the authoritative approved outbound destination list for the Squid image. Changes require security review and a new Squid image release.

Avoid overlapping Squid `dstdomain` entries. For example, `.example.com` already covers the apex/subdomains in the intended policy pattern, so a duplicate overlapping `example.com` entry should not also be added. Package lint checks this condition.

---

# Part H — POC distribution and Developer start

## 19. `scripts/poc/build-and-export.*`

This is the POC release builder called by `build-sandbox.*`. It builds and assesses the final DevContainer, builds Squid, exports both images as TAR files, and generates integrity metadata.

It is an Admin workflow. Developers do not build images from source.

## 20. `scripts/poc/load-and-start.*`

The POC Developer launcher:

```text
Developer runs load-and-start
  -> ensure .env exists
  -> validate required non-secret settings
  -> verify bundle hashes
  -> verify runtime policy hashes
  -> load DevContainer TAR
  -> load Squid TAR
  -> verify loaded image IDs against manifest
  -> start Compose
```

On first run, if `.env` does not exist, the launcher creates it from `.env.example` and asks the Developer to fill approved non-secret values such as `DEVELOPER_ID` before rerunning.

## 21. `scripts/poc/verify-sandbox.*`

The POC verification workflow checks the running environment: container state, network topology, read-only behavior, security options, expected proxy behavior, host logging paths, and other runtime controls that cannot be proven by static package lint alone.

---

# Part I — Production ECR distribution

## 22. `scripts/platform/02-setup-ecr.*`

This is the Production image build and publication workflow. It is responsible for approved ECR repositories/policies, final image builds, security gates, pushes, immutable digest capture, and approved-image manifest generation/publication.

The approved manifest is non-secret. It tells Developer launchers exactly which image digests are approved.

## 23. `scripts/ecr/pull-and-start.*`

This is the Production Developer launcher.

High-level sequence:

```text
Developer starts pull-and-start
  -> prepare non-secret AWS SSO profile
  -> verify AWS session
  -> if required, initiate browser-based SSO on Windows host
  -> read approved-images manifest from SSM
  -> authenticate to ECR
  -> pull exact DevContainer digest
  -> pull exact Squid digest
  -> verify registry/digest constraints
  -> tag to local approved runtime names
  -> start Production Compose with pull_policy: never
```

The launcher uses the centrally approved manifest so an image-only release normally does not require redistributing the entire Production Developer ZIP.

## 24. `scripts/ecr/deploy-ecr.*`

Despite the legacy-style name, this is a host/runtime provisioning helper, not the main image build path. The authoritative Production image release path is `scripts/platform/02-setup-ecr.*`, normally reached through `scripts/admin/build-sandbox.*`.

---

# Part J — Runtime startup sequence

## 25. What Compose starts

Both POC and Production Compose definitions create:

1. An `internal` Docker network with `internal: true`.
2. An `external` Docker bridge network.
3. A Squid container attached to both networks.
4. A DevContainer attached only to the internal network.
5. Persistent Developer state volumes for approved home/config paths.
6. Host bind mounts for DevContainer and Squid logs.
7. tmpfs mounts for temporary writable runtime paths.

DevContainer security options include:

```text
user: 1000:1000
read_only: true
cap_drop: ALL
no-new-privileges: true
core dumps disabled
memory/CPU/PID limits
selected sysctls
```

The DevContainer receives proxy environment variables pointing to Squid. It does not receive the external network.

## 26. `.devcontainer/devcontainer.json`

VS Code uses this file to select the Compose service, workspace path, non-root remote user, post-create command, forwarded development ports, extensions, and editor settings.

Important values:

```text
service            devcontainer
workspaceFolder    /home/vscode/workspace
remoteUser         vscode
postCreateCommand  post-create
```

The Windows Developer package still contains a top-level `workspace/` directory. Compose bind-mounts that host folder to `/home/vscode/workspace` inside the DevContainer. The project therefore lives under the `vscode` user's home in the container without changing the package layout on the Windows host.

## 27. `.devcontainer/post-create.sh`

`post-create` runs after the DevContainer is created and performs repeatable initialization. Application installation does **not** belong here; applications are installed during image build.

Current sequence:

```text
[1/5] Configure Git safe.directory
[2/5] Prepare AWS authentication (static key first, SSO fallback)
[3/5] Configure credential-value-free MCP definitions
[4/5] Run runtime security verification
[5/5] Run selected allowed/blocked egress probes
```

It then prints the Developer workflow and fails the post-create sequence if the runtime verification result is failed.

### 27.1 `configure-aws-sso` — non-secret profile bootstrap

`configure-aws-sso` prepares the named AWS CLI profile used by the Sandbox. In static-key mode it creates a non-secret compatibility stub containing only region/output settings so `SANDBOX_AWS_PROFILE=sandbox` is only a Sandbox-selected profile name and is not exported as AWS_PROFILE. Static credentials therefore remain the AWS CLI credential source; no key value is written to the profile. When no static key pair is present, the same helper uses the runtime non-secret SSO values supplied by the Developer package/Compose environment to create or update the managed IAM Identity Center profile in:

```text
/home/vscode/.aws/config
```

The generated profile contains SSO start URL, SSO region, account ID, role/permission-set role name, default AWS region, and profile/session names. It does not contain long-lived access keys, secret access keys, passwords, or SSO tokens.

### 27.2 `sandbox-aws-login` — static-key validation or host-browser SSO fallback

The application secret runner first checks for a complete static AWS key pair. If present, STS validates it and SSO is not attempted. If the static pair is absent and the SSO session is missing/expired, the runner invokes `sandbox-aws-login` for the browser fallback.

The intended user experience is:

```text
Developer runs claude/gemini/ucode/snyk/databricks/tvly
  -> AWS session check fails
  -> sandbox-aws-login
  -> aws sso login --use-device-code --no-browser
  -> terminal displays verification URL and one-time code
  -> Developer opens/completes the flow in Windows host Edge/Chrome
  -> corporate SSO/MFA completes
  -> AWS CLI receives temporary IAM Identity Center session
  -> original application execution continues
```

Developers should not need to remember or run `aws configure sso` when the Admin has preconfigured the package correctly.

### 27.3 Production host-browser login

The Windows Production `pull-and-start.ps1` must itself access STS/SSM/ECR before the container exists. It therefore uses the same priority: static AWS key pair from `.env` first, host-side browser SSO fallback second. The Windows host and DevContainer deliberately do not share a full credentials directory as a single trust store; each environment maintains the session material required for its own AWS CLI operations.

### 27.4 `sandbox-info`

Developers do not receive the Admin source package, so `sandbox-info` provides a supported diagnostic view of non-secret runtime/build state. It is intended to expose items such as Sandbox version, Databricks routing values, AWS profile/region/SSM prefix, installed tool provenance, and whether expected configuration paths exist, while hiding secret values.

---

# Part K — Runtime commands and SSM secrets

## 28. `sandbox-command-wrapper.sh`

The public command wrapper maps approved application commands to the appropriate SSM profile while allowing selected local-only operations such as safe version/help/config inspection to execute without fetching a credential.

Core mapping:

```text
claude      -> anthropic profile -> Anthropic official API
gemini      -> gemini profile    -> Google Gemini official API
ucode       -> databricks profile -> Databricks AI Gateway / coding-agent integration
databricks  -> databricks profile -> Databricks workspace API
tvly        -> tavily profile
snyk        -> snyk profile
```

The command name is intentionally the routing boundary. Bare `claude` and `gemini` never use the Databricks profile. Databricks routing for the coding agents is explicit through `ucode claude` or `ucode gemini`. For those two ucode routes, the runtime wrapper creates a short-lived `~/.databrickscfg` under `/tmp` from the SSM-fetched Databricks PAT, runs `ucode configure --profiles DEFAULT --use-pat --skip-validate --skip-upgrade`, launches the agent from the same temporary HOME, and removes the temporary state on exit. Interactive browser login and persistent `~/.databricks` token cache are not used.

The real vendor executable is resolved from `/usr/local/libexec/ai-sandbox/real/`. `ucode` is also stashed and wrapped so the Sandbox can inject the Databricks credential before the launcher starts. When ucode launches Claude or Gemini, the real vendor directory is placed before the public wrappers in `PATH` to prevent recursion back into the direct-provider routes.

## 29. `run-with-ssm-secrets.sh`

This is the central runtime secret broker.

High-level sequence:

```text
validate requested profile
  -> confirm required audit destination is writable when audit is mandatory
  -> validate static AWS credentials OR validate/refresh SSO fallback session
  -> fetch exact SSM parameter(s)
  -> export only required application environment variable(s)
  -> emit redacted credential/application lifecycle metadata
  -> execute child process
  -> emit completion status/duration
```

The script must not log secret values, full free-form prompts, full search queries, source code, tool request/response bodies, or complete command lines.

## 30. Current SSM parameter mapping

Default prefix: `/sandbox`.

| Integration | Parameter | Type | Runtime variable |
|---|---|---|---|
| Anthropic direct Claude | `/sandbox/claude-api-key` | SecureString | `ANTHROPIC_API_KEY` |
| Google direct Gemini | `/sandbox/gemini-api-key` | SecureString | `GEMINI_API_KEY` |
| Databricks / ucode | `/sandbox/databricks-token` | SecureString | `DATABRICKS_TOKEN` |
| Databricks managed SQL MCP | `/sandbox/databricks-sql-mcp-token` | SecureString | `DATABRICKS_SQL_MCP_TOKEN` (MCP child only) |
| Tavily | `/sandbox/tavily-api-key` | SecureString | `TAVILY_API_KEY` |
| Snyk | `/sandbox/snyk-token` | SecureString | `SNYK_TOKEN` |
| HiddenLayer | `/sandbox/hiddenlayer-client-id` | SecureString | `HIDDENLAYER_CLIENT_ID` |
| HiddenLayer | `/sandbox/hiddenlayer-client-secret` | SecureString | `HIDDENLAYER_CLIENT_SECRET` |
| ADO | `/sandbox/ado-org` | String | `ADO_ORG` |
| ADO | `/sandbox/ado-project` | String | `ADO_PROJECT` |
| ADO | `/sandbox/ado-repo` | String | `ADO_REPO` |
| ADO | `/sandbox/ado-pat` | SecureString | `ADO_PAT` |

v1.16.16 intentionally treats the SSM-backed ADO path as PAT-based. The previous partially implemented Service Principal parameter branch was removed to avoid presenting an incomplete authentication path as supported.

## 31. Direct Claude and Gemini execution flows

Bare Claude is the direct Anthropic route:

```text
Developer: claude
  -> /usr/local/bin/claude
  -> sandbox-command-wrapper
  -> run-with-ssm-secrets --profile anthropic
  -> AWS static credential STS check OR IAM Identity Center session check/login
  -> SSM /sandbox/claude-api-key
  -> ANTHROPIC_API_KEY injected into the Claude child process
  -> ANTHROPIC_BASE_URL forced to https://api.anthropic.com
  -> real Claude Code
  -> Anthropic official API
```

Bare Gemini is the direct Google route:

```text
Developer: gemini
  -> /usr/local/bin/gemini
  -> sandbox-command-wrapper
  -> run-with-ssm-secrets --profile gemini
  -> AWS static credential STS check OR IAM Identity Center session check/login
  -> SSM /sandbox/gemini-api-key
  -> GEMINI_API_KEY injected into the Gemini child process
  -> Databricks gateway variables explicitly neutralized for this child
  -> real Gemini CLI
  -> Google Gemini official API
```

The direct wrappers deliberately set provider routing/auth environment values at child-process launch. This protects the command contract even if a prior ucode session has written Databricks-oriented Claude/Gemini user configuration.

The AWS bootstrap credential is retained in direct AI-agent process trees only when static AWS authentication is selected because the Admin-managed Tavily/Snyk MCP wrappers may need to fetch their own SSM secrets later in the same AI session.

## 32. ucode / Databricks execution flow

`ucode` is the explicit Databricks route:

```text
Developer: ucode claude
  -> /usr/local/bin/ucode
  -> sandbox-command-wrapper
  -> run-with-ssm-secrets --profile databricks
  -> SSM /sandbox/databricks-token
  -> DATABRICKS_HOST + DATABRICKS_TOKEN supplied to real ucode
  -> real Claude binary resolved from /usr/local/libexec/ai-sandbox/real
  -> Databricks AI Gateway
```

```text
Developer: ucode gemini
  -> /usr/local/bin/ucode
  -> sandbox-command-wrapper
  -> run-with-ssm-secrets --profile databricks
  -> SSM /sandbox/databricks-token
  -> DATABRICKS_HOST + DATABRICKS_TOKEN supplied to real ucode
  -> real Gemini binary resolved from /usr/local/libexec/ai-sandbox/real
  -> Databricks AI Gateway
```

For `ucode claude`, `DATABRICKS_CLAUDE_MODEL` is mandatory and the Sandbox injects it with `--model` unless the Developer already supplied a model. For `ucode gemini`, `DATABRICKS_GEMINI_MODEL` is mandatory and the Sandbox injects it with `--model` (and `GEMINI_MODEL` for CLI compatibility). Both routes are configured headlessly from the SSM-fetched Databricks PAT; missing approved targets or unsupported headless-PAT ucode builds fail closed. Bare `gemini` explicitly clears the routed model and remains on the direct Google API.

Direct Databricks CLI commands still use the same Databricks SSM profile but do not pass the Databricks token into unrelated child processes.

## 33. Tavily CLI and MCP

Direct approved troubleshooting:

```bash
tvly search "query" --json
```

The public `tvly` command maps to the Tavily SSM profile.

For normal AI-agent use, Tavily is MCP-first:

```text
Claude/Gemini
  -> registered Tavily MCP command
  -> /usr/local/bin/tavily-mcp-ssm
  -> MCP lifecycle audit
  -> run-with-ssm-secrets --profile tavily
  -> TAVILY_API_KEY only in Tavily MCP child
  -> Squid
  -> Tavily API
```

The MCP registration itself contains no Tavily API key.

## 34. Snyk CLI and MCP

CLI example:

```bash
snyk test
```

The wrapper obtains `SNYK_TOKEN` through the Snyk SSM profile and executes the real Snyk CLI. `snyk test` generally evaluates open-source dependency metadata; `snyk code test`, container, IaC, and other modes are separate Snyk operations.

Snyk MCP uses the audited Snyk MCP wrapper and the same SSM-backed secret principle.

---

# Part L — Claude hooks and audit logging

## 35. `claude-audit-hook.sh`

Claude Code managed hooks are configured through `/etc/claude-code/managed-settings.json`. The hook receives Claude lifecycle/tool event JSON on stdin and writes an allowlisted metadata subset to the host-exported audit path.

Relevant event classes include:

```text
SessionStart
UserPromptSubmit
PreToolUse
PostToolUse
PostToolUseFailure
Stop
SessionEnd
```

The Drax audit hook intentionally avoids copying prompt text, assistant responses, tool input/output payloads, or transcript content into the host audit stream. Metadata such as event type, session identifier, tool name, tool-use identifier, model/reason information, and prompt length may be recorded when available.

## 36. `application-audit.sh`

This helper writes structured application lifecycle events for secret-backed integrations such as Databricks, Tavily, Snyk, ADO, HiddenLayer, Git attribution, and MCP lifecycle events.

The audit stream is metadata-oriented. It does not intentionally contain API keys, tokens, prompt/response content, Tavily search text, Snyk findings, source code, MCP request/response bodies, or complete command lines.

If `SANDBOX_AUDIT_REQUIRED=true`, the SSM-backed application path fails closed when the initial required application audit event cannot be written.

## 37. `sandbox-audit-logger.sh`

This provides general Sandbox/Git lifecycle logging functions used to capture higher-level activity categories without copying sensitive full command arguments or remote URLs into the security stream.

## 38. Host log layout

Recommended host path:

```text
C:\ProgramData\AI-Sandbox\Logs\
|-- devcontainer\
|   |-- audit.log
|   |-- security.log
|   |-- claude-events.log
|   |-- anthropic-events.log
|   |-- gemini-telemetry.log
|   |-- gemini-events.log
|   |-- databricks-events.log
|   |-- tavily-events.log
|   |-- snyk-events.log
|   |-- ado-events.log
|   |-- git-events.log
|   |-- hiddenlayer-events.log
|   `-- mcp-events.log
`-- squid\
    `-- access.log
```

Application-specific files are created when the corresponding integration is used.

---

# Part M — Host logging and Sentinel

## 39. `scripts/platform/03-setup-logging.*`

These scripts document/prepare host-side logging options. The Sandbox intentionally does not run a Sentinel forwarding agent as an additional privileged container sidecar.

Supported architectural options include:

```text
Host log files -> Azure Monitor Agent -> DCR -> Log Analytics -> Sentinel
```

or:

```text
Host log files -> Host sender -> Logs Ingestion API -> DCR -> Log Analytics -> Sentinel
```

## 40. `scripts/monitoring/verify-host-log-export.*`

These acceptance helpers verify that expected log files, redaction behavior, and host export paths are working. They are useful after POC/Production startup and before security acceptance.

## 41. `scripts/monitoring/send-logs-ingestion.*`

These are reference host-side senders for the Logs Ingestion API architecture. They are not intended to run inside the DevContainer.

## 42. `sentinel/`

The Sentinel directory contains example DCR definitions, onboarding notes, and KQL detection content. These are deployment/reference assets that must be adapted to the organization's Log Analytics/Sentinel environment.

---

# Part N — Azure DevOps helpers

## 43. ADO helper files

```text
ado-scripts/ado-auth-setup.*
ado-scripts/ado-pr-create.*
ado-scripts/ado-trigger.*
.devcontainer/scripts/git-askpass-ado.sh
```

### `ado-auth-setup.*`

Provides supported ADO authentication setup/check behavior according to the current package scope.

### `git-askpass-ado.sh`

A small POSIX `sh` helper used by Git's `GIT_ASKPASS` mechanism to provide the in-process `ADO_PAT` value without persisting it to a Git credential file.

### `ado-pr-create.*`

Helper for creating Azure DevOps pull requests using approved authentication and runtime configuration.

### `ado-trigger.*`

Helper for approved Azure DevOps pipeline trigger operations.

### ADO authentication scope

The SSM-backed ADO runtime path in v1.16.16 is PAT-based. If Azure CLI bearer-token mode is used by a separate helper, it depends on an already approved Azure CLI authentication context and should not be confused with the removed incomplete SSM Service Principal branch.

---

# Part O — What Developers can and cannot change

## 44. Runtime immutable areas

The following are intended to remain Admin/image-controlled because the root filesystem is read-only and the Developer is non-root:

```text
/etc/claude-code/managed-settings.json
/etc/ai-sandbox/*
/usr/local/bin/run-with-ssm-secrets
/usr/local/bin/claude-audit-hook
/usr/local/bin/configure-mcp
/usr/local/bin/configure-aws-sso
/usr/local/bin/sandbox-aws-login
/usr/local/libexec/ai-sandbox/sandbox-command-wrapper
/usr/local/libexec/ai-sandbox/real/*
```

Developers should not be able to replace the approved wrapper, alter the managed Claude hook policy, modify installed global vendor binaries, or change the Squid image configuration from inside the running DevContainer.

## 45. Writable areas

Approved writable state is provided through workspace bind mounts, persistent Docker volumes, and tmpfs. Examples include:

```text
/home/vscode/workspace
/home/vscode/.claude
/home/vscode/.gemini
/home/vscode/.aws
/home/vscode/.azure
/home/vscode/.config/git
/home/vscode/.config/gh
/home/vscode/.cache
/home/vscode/.local
/home/vscode/.npm
/home/vscode/.vscode-server
/tmp
/var/tmp
/run
```

User-level application configuration may therefore be changed where the product normally stores it. That does not grant permission to modify the Admin-controlled system/security configuration.

### AWS authentication state note

In SSO fallback mode, AWS CLI stores temporary SSO token/session cache material under the user's AWS directory. In static-key mode, the Access Key/Secret Key are supplied through the runtime environment instead and are not written to the managed SSO profile. Because container environment values are inspectable by the Developer/container runtime, static-key mode is a deliberate security trade-off and `.env` must be protected. In addition, Claude and Gemini retain the AWS bootstrap pair in their process tree because their SSM-backed MCP servers are started later and must authenticate to SSM; leaf application processes have the bootstrap pair removed after their SSM fetch.

---

# Part P — Developer package export boundary

## 46. `scripts/admin/export-developer-packages.*`

The export scripts enforce separation between the Admin source package and the minimal Developer runtime package.

### POC Developer package

Contains only the files required to load/start the approved POC images, runtime policy/integrity metadata, Developer-facing configuration/documentation, workspace content, and the built TAR images when `-IncludePocImages` is used.

The POC package should not contain Admin build/hardening/supply-chain source that the Developer does not need.

### Production Developer package

Contains the Production Compose/runtime launcher, minimal configuration, Developer guide, runtime policy, workspace, and other files required to resolve the centrally approved ECR digests and start the environment.

It does not contain Admin build source, image-build secrets, Ubuntu Pro material, or the full security engineering package.

---

# Part Q — Static QA and package lint

## 47. `scripts/ci/lint-package.*`

Package lint is the static regression gate. It validates, among other things:

- Bash syntax.
- PowerShell/script contract where supported by the running environment.
- JSON/YAML parsing.
- Required files.
- Two-container DevContainer + Squid contract.
- Absence of obsolete monitoring-sidecar patterns.
- Host log bind mounts.
- Gemini prompt logging disabled.
- Claude managed audit hook wiring.
- Application audit helper presence.
- SSM-aware public command wrapper installation.
- Tavily MCP secret-free registration.
- Databricks/Tavily/Snyk routing invariants.
- Required application audit defaults.
- Redaction regression rules.
- Unsafe Docker runtime patterns.
- Obvious committed-secret patterns.
- Bash/PowerShell workflow-pair coverage.
- Squid allowlist overlap.

Static lint does not replace real Docker build, runtime, SSO, SSM, network, SaaS, ECR, or Sentinel acceptance testing.

---

# Part R — Change impact and application maintenance

## 48. Adding a new application

Use `docs/ADMIN-APPLICATION-ADD-REMOVE.md` as the authoritative runbook.

v1.16.16 provides Admin-only helpers:

```text
scripts/applications/add-application.ps1/.sh
scripts/applications/remove-application.ps1/.sh
scripts/applications/validate-application.ps1/.sh
scripts/applications/application-helper.py
```

The helper does **not** introduce a runtime application catalog. It writes explicit reviewed blocks into the same Dockerfile/wrapper/SSM/audit/Squid/verification source files used by the v1.16.3 architecture.

Operational pattern:

```text
collect vendor/security inputs
  -> run add helper in Preview mode
  -> review proposed source edits
  -> Apply
  -> validate application integration
  -> run full package lint
  -> build POC
  -> perform runtime/security acceptance
  -> release new immutable Production image digest
```

Typical integration points for a secret-backed CLI are:

```text
.build.env.example                 optional build version/source/hash
scripts/common/Load-BuildEnv.*    required build-value validation
scripts/poc/build-and-export.*     POC Docker build args
scripts/platform/02-setup-ecr.*   Production Docker build args
.devcontainer/Dockerfile          install/stash/writable paths/wrappers
sandbox-command-wrapper.sh        public command route
run-with-ssm-secrets.sh           SSM profile + child-process injection
scripts/platform/01-setup-ssm.*   Admin SSM parameter provisioning
application-audit.sh              application audit allowlisting
configure-mcp.sh                  MCP registration when applicable
<app>-mcp-ssm.sh                  MCP launcher when applicable
squid/whitelist.txt               external destinations when required
verify-runtime.sh                 runtime invariant checks
scripts/ci/lint-package.*         static regression checks
```

Installation methods differ by vendor. Do not force every application into one generic installer when the vendor supply-chain method is materially different. Exact npm versions, exact uv/Python versions, reviewed apt packages, SHA-256 verified archives, and reviewed custom vendor installation steps are all valid patterns when approved.

## 49. Removing an application

Removal must reverse every integration point and must not delete a credential too early.

Preferred sequence:

```text
review dependencies/shared domains/shared parameters
  -> Preview helper removal when helper-managed
  -> remove image/wrapper/SSM/audit/MCP/Squid/verification integration
  -> lint
  -> build/test new image
  -> publish new approved digest
  -> retire old image instances
  -> revoke vendor credential/delete SSM parameter only after retirement
```

Built-in applications or exceptional manually integrated applications should follow the manual removal section of the application runbook.

## 50. Base/tool version update

A version update is a release change even when no new feature is added. Re-run supply-chain resolution, update exact hashes/commits, rebuild the image, rerun final security assessment, regenerate release evidence, and publish a new immutable digest.

## 51. Squid allowlist change

A Squid allowlist change requires a new Squid image because the allowlist is baked into the Squid image. Review whether the destination is least-privilege, whether it overlaps an existing suffix rule, and whether an upstream corporate web-control layer is also required.

---

# Part S — Known constraints and technical debt

## 52. ADO authentication scope

The package now documents the SSM-backed ADO path as PAT-only. This is intentionally simpler and clearer than retaining unused Service Principal variables that were not connected end to end.

## 53. Installer pinning differences

Not every package ecosystem provides the same level of immutable pinning. Direct downloads should use SHA-256. npm packages use exact versions. ucode uses an immutable Git commit. Ubuntu apt packages and some vendor installers require organization-specific repository snapshotting/version-control policy if exact package reproducibility is a strict requirement.

## 54. Local scratch registry references

The hardened-base workflow may use a local registry to obtain an immutable digest reference during the Admin build. Production distribution remains ECR; the scratch registry should not be interpreted as a Developer-facing registry trust boundary.

## 55. Build cache

Some security-sensitive release builds intentionally use `--no-cache`. This improves reproducibility/audit clarity at the cost of build time. If build caching is later introduced, cache provenance and invalidation behavior should be reviewed as part of the supply-chain policy.

---

# Part T — Troubleshooting order

## 56. Build fails early

Check in this order:

1. `.build.env` exists.
2. Required placeholder values have been replaced or resolvers can replace them.
3. Docker Desktop is running and the Admin can build/pull images.
4. Base digest resolver succeeds.
5. Tool artifact resolver succeeds.
6. `scripts/ci/lint-package.*` passes.
7. Required organization proxy/registry access is available.

## 57. Hardened-base build fails

Check:

1. Selected SandboxType.
2. Ubuntu Pro token only for non-POC builds.
3. SSG URL/version/hash consistency.
4. Docker BuildKit support.
5. Scratch/local registry availability when used.
6. OpenSCAP/USG report output for the actual failed rule.
7. Approved CIS tailoring status.

## 58. Final OpenSCAP assessment fails

Do not assume the hardened base is wrong. The final assessment happens after application/tool layers are added. Review the final report for changes introduced by package installation, file permissions, users/groups, service state, SUID/SGID files, or runtime preparation.

## 59. `claude`, `gemini`, `snyk`, `databricks`, or `tvly` fails at runtime

Check:

```text
sandbox-info
aws sts get-caller-identity --profile <configured profile>
AWS SSO browser/device login status
SSM parameter existence and GetParameter permission
application audit log writeability
Squid access.log
application-specific event log
public command -> wrapper mapping
real executable presence
```

Do not debug by copying application/service secrets into `.env` or the parent shell. Only the approved AWS bootstrap key pair may be present in `.env` when static-key mode is intentionally selected.

## 60. Databricks route fails

Check:

```text
DATABRICKS_HOST
DATABRICKS_CLAUDE_MODEL
DATABRICKS_GEMINI_MODEL
/sandbox/databricks-token
/sandbox/databricks-sql-mcp-token (for managed SQL MCP)
AWS profile/region/SSM prefix
ucode installation/status
Databricks hostname in Squid allowlist
Squid access log
Databricks application audit log
```

The Workspace/provider values are non-secret runtime values. The Databricks token remains SSM-managed. Bare `claude` and `gemini` are separate direct-provider routes and should be debugged against `/sandbox/claude-api-key` or `/sandbox/gemini-api-key` plus their official provider egress.

---

# Part U — Authoritative document and source inventory

## 61. Documentation and active templates

The package deliberately separates optional human documentation from active generation inputs.

| File | Classification | Purpose |
|---|---|---|
| `README.md` | Package entry point | Short architecture and package-boundary summary. |
| `docs/ADMIN-COMPLETE-GUIDE.md` | Optional documentation | This complete architecture/build/runtime/maintenance guide. |
| `docs/ADMIN-APPLICATION-ADD-REMOVE.md` | Optional documentation | Detailed application add/remove runbook. |
| `docs/SECURITY-LOGGING-AND-SENTINEL.md` | Optional documentation | Security boundary, runtime audit/log content policy, host logging, Sentinel. |
| `templates/developer/env.example` | Active template | Source for exported Developer `.env.example`. |
| `templates/developer/devcontainer-production.json` | Active template | Source for exported Production Developer DevContainer definition. |
| `templates/developer/DEVELOPER-GUIDE-POC.md` | Active template | Source for the POC Developer guide shipped in the Developer package. |
| `templates/developer/DEVELOPER-GUIDE-PRODUCTION.md` | Active template | Source for the Production Developer guide shipped in the Developer package. |

Release-history, QA-evidence, language-audit, and package-cleanup reports are intentionally not part of the active Admin build package.

## 62. DevContainer runtime source

The authoritative runtime source is under `.devcontainer/`. The Dockerfile installs the approved stack and bakes the scripts into read-only system locations. `devcontainer.json` defines VS Code behavior. `post-create.sh` performs repeatable initialization. `.devcontainer/scripts/` contains the SSM, audit, MCP, SSO, command-wrapper, and runtime-verification controls.

## 63. Admin build orchestration

`scripts/admin/` contains the top-level build and Developer-package export entry points. `scripts/supply-chain/` resolves external immutable inputs. `scripts/hardening/` creates the base. `scripts/security/` assesses the final image. `scripts/poc/` builds/exports/starts POC. `scripts/platform/` handles SSM/ECR/logging platform setup. `scripts/ecr/` contains Production Developer pull/start and supporting host provisioning.

## 64. Application Admin helpers

`scripts/applications/` contains only Admin-side source editing/validation helpers. These helpers are not a runtime plugin framework and should not be shipped as a way for Developers to install arbitrary approved/unapproved applications at runtime.

## 65. Runtime/platform/security assets

`squid/` defines the controlled egress image. `security/` defines CIS/OpenSCAP content and scanner build assets. `policies/` contains Docker Desktop/Admin policy examples. `sentinel/` contains SIEM onboarding/detection reference assets. `workspace/` is the Developer work area template.

---

# Part V — Operational summary

## 70. Eight steps an Admin should remember

1. Review `.build.env` and organization-specific non-secret values.
2. Run package lint.
3. Resolve upstream image digests and tool hashes/commits.
4. Build the hardened base, or explicitly use `-ReuseHardenedBase` and confirm the reuse validation passes.
5. Build the final DevContainer and Squid from the same hardened base digest.
6. Run final-image security assessment and preserve evidence.
7. Distribute POC TAR images or publish immutable Production ECR digests/manifest.
8. Export only the minimal Developer package and complete target-environment acceptance.

## 71. Five steps a Developer should remember

1. Use the provided Developer package; do not build the Admin image source.
2. Set required non-secret Developer values such as `DEVELOPER_ID` when instructed.
3. Start the Sandbox with the provided POC or Production launcher.
4. Use the approved static AWS key pair when supplied; otherwise complete AWS SSO/MFA in the Windows host browser when prompted.
5. Use approved commands normally: `claude`, `gemini`, `ucode claude`, `ucode gemini`, `snyk`, `databricks`, and approved MCP tools.

## 72. Five control planes a security reviewer should remember

1. **Host control plane:** Windows 365, endpoint controls, Docker Desktop Business/ECI/settings enforcement.
2. **Image control plane:** hardened base, immutable build inputs, final OpenSCAP assessment, ECR/TAR integrity evidence.
3. **Runtime privilege control plane:** non-root, read-only rootfs, capability drop, no-new-privileges, no Docker socket.
4. **Identity/secret control plane:** static AWS runtime credentials when explicitly supplied, otherwise IAM Identity Center temporary sessions; both feed SSM child-process secret injection.
5. **Network/audit control plane:** internal-only DevContainer network, Squid default-deny egress, host-exported redacted audit logs, Sentinel forwarding.

---

# Appendix A — Complete file inventory, execution point, and role

The table below describes every source file currently present in the cleaned Admin package. Generated build outputs such as `.build.env`, hardened-base artifacts, security reports, POC TARs, and approved image manifests are listed separately after the source inventory.

| File | Category | Execution/use point | Role |

|---|---|---|---|

| `.build.env.example` | Admin build configuration | Before every release build | Template for pinned versions, hashes, image references, security gates, and optional non-secret Developer SSO fallback defaults. |

| `.devcontainer/Dockerfile` | DevContainer image | Admin image build | Builds approved Developer runtime from hardened base, installs tools, stashes real executables, and bakes security controls. |

| `.devcontainer/cis-level1-harden.sh` | DevContainer hardening | Image build | Applies reviewed image-level hardening before final assessment. |

| `.devcontainer/devcontainer.json` | VS Code Dev Container | VS Code open/reopen | Selects Compose service, workspace, remote user, extensions, ports, and post-create command. |

| `.devcontainer/post-create.sh` | DevContainer initialization | After container creation | Prepares Git, AWS authentication (static key or SSO fallback), MCP definitions, runtime verification, and egress probes. |

| `.devcontainer/scripts/application-audit.sh` | DevContainer runtime control | Image build and/or runtime | Writes structured redacted application lifecycle audit events. |

| `.devcontainer/scripts/claude-audit-hook.sh` | DevContainer runtime control | Image build and/or runtime | Processes Claude Code managed-hook events and records allowlisted metadata only. |

| `.devcontainer/scripts/configure-aws-sso.sh` | DevContainer runtime control | Image build and/or runtime | When static AWS credentials are selected, creates/updates a non-secret compatibility profile stub so the default and named `SANDBOX_AWS_PROFILE` configuration is available without persisting keys; otherwise creates/updates the non-secret IAM Identity Center fallback profile in the Developer home directory. |

| `.devcontainer/scripts/configure-mcp.sh` | DevContainer runtime control | Image build and/or runtime | Registers secret-free Tavily/Snyk MCP commands for Claude/Gemini. |

| `.devcontainer/scripts/git-askpass-ado.sh` | DevContainer runtime control | Image build and/or runtime | POSIX Git askpass helper that returns the in-process ADO PAT without credential-file persistence. |

| `.devcontainer/scripts/run-with-ssm-secrets.sh` | DevContainer runtime control | Image build and/or runtime | Central runtime broker for AWS session validation, SSM retrieval, child-process secret injection, and audit. |

| `.devcontainer/scripts/sandbox-audit-logger.sh` | DevContainer runtime control | Image build and/or runtime | General Sandbox/Git lifecycle metadata logger. |

| `.devcontainer/scripts/sandbox-aws-login.sh` | DevContainer runtime control | Image build and/or runtime | Validates static AWS credentials when configured; otherwise starts IAM Identity Center device authorization for completion in the Windows host browser. |

| `.devcontainer/scripts/sandbox-command-wrapper.sh` | DevContainer runtime control | Image build and/or runtime | Maps approved public commands to real binaries and SSM profiles. |

| `.devcontainer/scripts/sandbox-info.sh` | DevContainer runtime control | Image build and/or runtime | Displays non-secret runtime/build diagnostics to Developers. |

| `.devcontainer/scripts/snyk-mcp-ssm.sh` | DevContainer runtime control | Image build and/or runtime | Audited SSM-aware stdio launcher for Snyk MCP. |

| `.devcontainer/scripts/tavily-mcp-ssm.sh` | DevContainer runtime control | Image build and/or runtime | Audited SSM-aware stdio launcher for Tavily MCP. |

| `.devcontainer/scripts/verify-runtime.sh` | DevContainer runtime control | Image build and/or runtime | Checks runtime security invariants, wrapper wiring, files, mounts, and expected configuration. |

| `.dockerignore` | Docker build hygiene | Docker build context creation | Excludes non-build files/secrets/artifacts from repository-root Docker build context. |

| `.env.example` | Runtime configuration | Developer package startup | Template for runtime endpoints, optional AWS static bootstrap credentials or SSO fallback/SSM routing, audit identity, and optional service endpoints. |


| `README.md` | Documentation | Package entry | Short architecture summary, supported entry points, and authoritative document index. |

| `ado-scripts/ado-auth-setup.ps1` | Azure DevOps helper | Admin/Developer approved ADO operation | ADO authentication/check, PR creation, or pipeline trigger helper with current supported auth scope. |

| `ado-scripts/ado-auth-setup.sh` | Azure DevOps helper | Admin/Developer approved ADO operation | ADO authentication/check, PR creation, or pipeline trigger helper with current supported auth scope. |

| `ado-scripts/ado-pr-create.ps1` | Azure DevOps helper | Admin/Developer approved ADO operation | ADO authentication/check, PR creation, or pipeline trigger helper with current supported auth scope. |

| `ado-scripts/ado-pr-create.sh` | Azure DevOps helper | Admin/Developer approved ADO operation | ADO authentication/check, PR creation, or pipeline trigger helper with current supported auth scope. |

| `ado-scripts/ado-trigger.ps1` | Azure DevOps helper | Admin/Developer approved ADO operation | ADO authentication/check, PR creation, or pipeline trigger helper with current supported auth scope. |

| `ado-scripts/ado-trigger.sh` | Azure DevOps helper | Admin/Developer approved ADO operation | ADO authentication/check, PR creation, or pipeline trigger helper with current supported auth scope. |

| `docs/ADMIN-APPLICATION-ADD-REMOVE.md` | Documentation | Review/operations/acceptance | Detailed Admin application add/remove helper and manual fallback runbook. |

| `templates/developer/devcontainer-production.json` | Developer package template | Developer package export/direct deployment | Production Developer DevContainer definition used as an active generation input. |

| `templates/developer/env.example` | Developer package template | Developer package export/direct deployment | Developer-facing non-secret runtime environment template used as an active generation input. |

| `templates/developer/DEVELOPER-GUIDE-POC.md` | Developer package template | Developer package export | POC Developer start/login/use/verification guide copied into the exported package. |

| `templates/developer/DEVELOPER-GUIDE-PRODUCTION.md` | Developer package template | Developer package export | Production Developer pull/start/login/use guide copied into the exported package. |


| `docs/SECURITY-LOGGING-AND-SENTINEL.md` | Documentation | Review/operations/acceptance | Security boundaries, audit content policy, host logging, and Sentinel forwarding. |


| `ecr/docker-compose.yml` | Production Compose/runtime | Production Developer startup | Production two-container Compose definition using locally tagged approved immutable images. |

| `poc/docker-compose.yml` | POC Compose/runtime | POC Developer startup | POC two-container Compose definition for TAR-loaded approved images. |

| `policies/admin-settings.json` | Host/Docker policy | Endpoint provisioning | Example centrally managed Docker Desktop/Admin security settings. |

| `scripts/admin/build-sandbox.ps1` | Admin orchestration | Admin release workflow | Top-level Sandbox build orchestration, including validated `-ReuseHardenedBase` optimization and automatic full-build fallback. |

| `scripts/admin/build-sandbox.sh` | Admin orchestration | Admin release workflow | Top-level Sandbox build orchestration, including validated `-ReuseHardenedBase` optimization and automatic full-build fallback. |

| `scripts/admin/export-developer-packages.ps1` | Admin orchestration | Admin release workflow | Top-level Sandbox build orchestration, including validated `-ReuseHardenedBase` optimization and automatic full-build fallback. |

| `scripts/admin/export-developer-packages.sh` | Admin orchestration | Admin release workflow | Top-level Sandbox build orchestration, including validated `-ReuseHardenedBase` optimization and automatic full-build fallback. |

| `scripts/applications/add-application.ps1` | Application maintenance | Admin add/remove/validate workflow | Admin-only helper for explicit source integration changes; not a runtime application catalog. |

| `scripts/applications/add-application.sh` | Application maintenance | Admin add/remove/validate workflow | Admin-only helper for explicit source integration changes; not a runtime application catalog. |

| `scripts/applications/application-helper.py` | Application maintenance | Admin add/remove/validate workflow | Admin-only helper for explicit source integration changes; not a runtime application catalog. |

| `scripts/applications/records/README.md` | Application maintenance | Admin add/remove/validate workflow | Admin-only helper for explicit source integration changes; not a runtime application catalog. |

| `scripts/applications/remove-application.ps1` | Application maintenance | Admin add/remove/validate workflow | Admin-only helper for explicit source integration changes; not a runtime application catalog. |

| `scripts/applications/remove-application.sh` | Application maintenance | Admin add/remove/validate workflow | Admin-only helper for explicit source integration changes; not a runtime application catalog. |

| `scripts/applications/validate-application.ps1` | Application maintenance | Admin add/remove/validate workflow | Admin-only helper for explicit source integration changes; not a runtime application catalog. |

| `scripts/applications/validate-application.sh` | Application maintenance | Admin add/remove/validate workflow | Admin-only helper for explicit source integration changes; not a runtime application catalog. |

| `scripts/ci/lint-package.ps1` | Static QA | Before/after package changes and release build | Static syntax, structure, security, redaction, wrapper, package-boundary, and Squid regression checks. |

| `scripts/ci/lint-package.sh` | Static QA | Before/after package changes and release build | Static syntax, structure, security, redaction, wrapper, package-boundary, and Squid regression checks. |

| `scripts/common/Load-BuildEnv.ps1` | Build configuration | Called by Admin build scripts | Safe parser/validator for .build.env shared by platform build workflows. |

| `scripts/common/load-build-env.sh` | Build configuration | Called by Admin build scripts | Safe parser/validator for .build.env shared by platform build workflows. |

| `scripts/ecr/deploy-ecr.ps1` | Production host provisioning | Optional Admin/host setup | Supporting ECR/host deployment helper; not the primary Production image build entry point. |

| `scripts/ecr/deploy-ecr.sh` | Production host provisioning | Optional Admin/host setup | Supporting ECR/host deployment helper; not the primary Production image build entry point. |

| `scripts/ecr/pull-and-start.ps1` | Production Developer runtime | Developer startup | Performs static-key-or-SSO authentication, SSM/ECR approved-digest resolution, and starts Production Compose. |

| `scripts/ecr/pull-and-start.sh` | Production Developer runtime | Developer startup | Performs static-key-or-SSO authentication, SSM/ECR approved-digest resolution, and starts Production Compose. |

| `scripts/hardening/build-hardened-base.ps1` | Base hardening | Admin POC/Production build | Creates hardened base image/evidence using POC OpenSCAP or Production Ubuntu Pro/USG path. |

| `scripts/hardening/build-hardened-base.sh` | Base hardening | Admin POC/Production build | Creates hardened base image/evidence using POC OpenSCAP or Production Ubuntu Pro/USG path. |

| `scripts/monitoring/send-logs-ingestion.ps1` | Host logging integration | Optional host-side forwarding | Reference host-side Logs Ingestion API sender; not an in-Sandbox sidecar. |

| `scripts/monitoring/send-logs-ingestion.sh` | Host logging integration | Optional host-side forwarding | Reference host-side Logs Ingestion API sender; not an in-Sandbox sidecar. |

| `scripts/monitoring/verify-host-log-export.ps1` | Host logging QA | Acceptance testing | Verifies host-exported log files, redaction behavior, and forwarding prerequisites. |

| `scripts/monitoring/verify-host-log-export.sh` | Host logging QA | Acceptance testing | Verifies host-exported log files, redaction behavior, and forwarding prerequisites. |

| `scripts/platform/01-setup-ssm.ps1` | SSM provisioning | Admin environment setup | Creates/updates expected application SSM parameter names and prompts Admin for real values. |

| `scripts/platform/01-setup-ssm.sh` | SSM provisioning | Admin environment setup | Creates/updates expected application SSM parameter names and prompts Admin for real values. |

| `scripts/platform/02-setup-ecr.ps1` | Production image release | Admin Production build | Builds/assesses/pushes DevContainer and Squid, captures ECR digests, and publishes approved manifest. |

| `scripts/platform/02-setup-ecr.sh` | Production image release | Admin Production build | Builds/assesses/pushes DevContainer and Squid, captures ECR digests, and publishes approved manifest. |

| `scripts/platform/03-setup-logging.ps1` | Host logging setup | Security/endpoint provisioning | Prepares/documents AMA or Logs Ingestion host-forwarding mode. |

| `scripts/platform/03-setup-logging.sh` | Host logging setup | Security/endpoint provisioning | Prepares/documents AMA or Logs Ingestion host-forwarding mode. |

| `scripts/poc/build-and-export.ps1` | POC image release | Admin POC build | Builds final images, assesses DevContainer, exports TARs, and generates integrity metadata. |

| `scripts/poc/build-and-export.sh` | POC image release | Admin POC build | Builds final images, assesses DevContainer, exports TARs, and generates integrity metadata. |

| `scripts/poc/load-and-start.ps1` | POC Developer runtime | Developer startup | Verifies bundle/policy/image IDs, loads approved TARs, and starts POC Compose. |

| `scripts/poc/load-and-start.sh` | POC Developer runtime | Developer startup | Verifies bundle/policy/image IDs, loads approved TARs, and starts POC Compose. |

| `scripts/poc/verify-sandbox.ps1` | POC runtime QA | POC acceptance | Validates running container/network/read-only/egress/log controls. |

| `scripts/poc/verify-sandbox.sh` | POC runtime QA | POC acceptance | Validates running container/network/read-only/egress/log controls. |

| `scripts/security/assess-cis-l1.ps1` | Final image security gate | POC/Production image release | Runs final DevContainer OpenSCAP/CIS assessment using a dedicated scanner image. |

| `scripts/security/assess-cis-l1.sh` | Final image security gate | POC/Production image release | Runs final DevContainer OpenSCAP/CIS assessment using a dedicated scanner image. |

| `scripts/supply-chain/resolve-base-digests.ps1` | Supply-chain resolution | Early Admin build | Resolves immutable upstream image digests or downloadable tool hashes/commits and updates .build.env. |

| `scripts/supply-chain/resolve-base-digests.sh` | Supply-chain resolution | Early Admin build | Resolves immutable upstream image digests or downloadable tool hashes/commits and updates .build.env. |

| `scripts/supply-chain/resolve-tool-artifacts.ps1` | Supply-chain resolution | Early Admin build | Resolves immutable upstream image digests or downloadable tool hashes/commits and updates .build.env. |

| `scripts/supply-chain/resolve-tool-artifacts.sh` | Supply-chain resolution | Early Admin build | Resolves immutable upstream image digests or downloadable tool hashes/commits and updates .build.env. |

| `security/CIS-TAILORING-README.md` | Security guidance | CIS review/acceptance | CIS tailoring and security assessment guidance. |

| `security/cis-scanner/Dockerfile` | Security scanner image | Final image assessment | Dedicated OpenSCAP/ComplianceAsCode scanner image; not part of Developer runtime. |

| `sentinel/README.md` | Sentinel asset | SIEM onboarding/detection engineering | Reference DCR, ingestion, or KQL content for Sandbox host logs. |

| `sentinel/dcr-ama-custom-text.example.json` | Sentinel asset | SIEM onboarding/detection engineering | Reference DCR, ingestion, or KQL content for Sandbox host logs. |

| `sentinel/dcr-logs-ingestion.example.json` | Sentinel asset | SIEM onboarding/detection engineering | Reference DCR, ingestion, or KQL content for Sandbox host logs. |

| `sentinel/detection-rules.kql` | Sentinel asset | SIEM onboarding/detection engineering | Reference DCR, ingestion, or KQL content for Sandbox host logs. |

| `squid/Dockerfile` | Squid image | POC/Production build | Builds internally controlled Squid proxy image from the approved hardened base. |

| `squid/squid.conf` | Egress policy | Squid runtime | Default-deny proxy ACL, CONNECT, cache, manager, and logging policy. |

| `squid/whitelist.txt` | Egress allowlist | Squid build/runtime | Approved outbound destination domains; changes require Squid rebuild/release. |

| `workspace/README.md` | Developer workspace | Developer runtime | Documents the writable project workspace boundary. |



## Appendix A.1 Generated files not present in the source ZIP

| Generated artifact | Created by | Meaning |
|---|---|---|
| `.build.env` | Admin / `build-sandbox.*` first run | Actual release build inputs after review/resolution. Normally excluded from source distribution. |
| `hardened-base-build/hardened-base.env` | `build-hardened-base.*` | Passes immutable hardened base references back to the parent build. |
| `security/reports/*` | OpenSCAP/USG workflows | Security assessment evidence. |
| `poc/images/sandbox-devcontainer.tar` | `build-and-export.*` | Approved POC DevContainer image bundle. |
| `poc/images/sandbox-squid.tar` | `build-and-export.*` | Approved POC Squid image bundle. |
| `poc/images/image-manifest.*` | `build-and-export.*` | Approved image IDs and release metadata. |
| `poc/images/runtime-policy.sha256` | `build-and-export.*` | Hashes of runtime policy files delivered with the POC release. |
| `poc/images/SHA256SUMS` | `build-and-export.*` | Integrity list for the POC image/evidence bundle. |
| `approved-images.json` or equivalent manifest output | Production ECR workflow | Immutable approved ECR DevContainer/Squid digests for Developer runtime resolution. |
| `~/.aws/config` managed block | `configure-aws-sso` | Admin-managed non-secret AWS profile configuration. Static-key mode contains only a compatibility profile stub (region/output; no credentials); SSO mode contains the IAM Identity Center session/profile configuration. |
| `~/.aws/sso/cache/*` | AWS CLI after SSO | Temporary SSO token/session cache material. |
| `~/.claude/*`, `~/.gemini/*` | Vendor tools/runtime configuration | Developer-owned persistent user-level state where the tools create it. |
| Host `devcontainer/*.log` and `squid/access.log` | Runtime containers | Host-visible audit/security/application/network logs for forwarding/retention. |

---

# Appendix B — Application add/remove quick reference

For complete procedures use `docs/ADMIN-APPLICATION-ADD-REMOVE.md`.

### Add

```text
1. Collect approval, owner, exact version/source/hash, commands, secrets, domains, MCP needs.
2. Run add helper in Preview mode where supported.
3. Review every proposed source change.
4. Apply.
5. Validate application integration.
6. Run package lint.
7. Build POC images.
8. Test real approved operation with non-production/dummy credentials where appropriate.
9. Confirm audit contains no secret/query/prompt/source-code leakage.
10. Run security gates.
11. Publish a new immutable Production image digest and update release evidence.
```

### Remove

```text
1. Identify shared dependencies/domains/parameters first.
2. Preview removal where helper-managed.
3. Remove all image/wrapper/SSM/audit/MCP/Squid/verification references.
4. Lint and rebuild.
5. Test and publish new immutable image.
6. Retire old image instances.
7. Only then revoke/delete application credentials and obsolete SSM parameters.
```

---

# Appendix C — Final acceptance checklist

Before a Production release, confirm at minimum:

- Admin package lint passes in Bash and PowerShell-capable environments.
- Pinned/resolved external inputs match the approved change record.
- Hardened-base evidence is preserved.
- Final DevContainer OpenSCAP/CIS gate passes according to Production policy.
- Squid starts healthy and only approved egress destinations work.
- Direct DevContainer Internet bypass is not available through the intended Docker network topology.
- Docker Desktop/Windows host policy prevents Developers from bypassing the approved Sandbox with arbitrary unmanaged runtime paths according to organizational policy.
- AWS authentication works with an approved runtime Access Key/Secret Key pair when supplied and otherwise falls back to IAM Identity Center browser login.
- SSM `GetParameter` least-privilege access works for required parameters.
- Bare Claude reaches the Anthropic official API end to end.
- Bare Gemini reaches the Google Gemini official API end to end.
- `ucode claude` and `ucode gemini` reach Databricks AI Gateway end to end.
- Tavily MCP and Snyk paths work end to end.
- Application audit and Claude/Gemini telemetry behave as documented.
- Prompt/query/secret/source-code redaction tests pass.
- Host log bind mounts are populated.
- AMA/DCR or Logs Ingestion forwarding to Sentinel is verified where required.
- ECR image digests and approved manifest match the release evidence.
- Developer package contains only the intended runtime boundary.

This guide is intentionally English-only so the Admin source, comments, operational documentation, and security review material use one consistent language.

## v1.16.16 optional AI content logging

The Developer runtime template includes `SANDBOX_CONTENT_LOGGING=false`. Keep the default for normal secure development. To enable approved POC/debug capture, set:

```env
SANDBOX_CONTENT_LOGGING=true
```

Recreate/restart the DevContainer so Compose passes the changed value. No SSM secret or image rebuild is required when only toggling this runtime flag.

Expected content-bearing files on the DevContainer/host bind mount are `claude-content.log`, `gemini-content.log`, `ucode-claude-content.log`, and `ucode-gemini-content.log`. Bare commands are direct-provider routes; `ucode` files identify Databricks-routed sessions. Existing event logs remain content-free.

The Admin must treat content files differently from ordinary audit metadata. Before enabling, approve scope, RBAC, retention, Sentinel forwarding behavior, incident-access procedure, and whether customer/source-code content may leave the Windows 365 host.


## POC fast iteration: skip final CIS/OpenSCAP assessment

For repeated POC-only development builds on constrained Admin workstations, the final DevContainer CIS/OpenSCAP scanner can be skipped explicitly:

```powershell
pwsh -NoProfile -File .\scripts\admin\build-sandbox.ps1 `
  -SandboxType POC `
  -ReuseHardenedBase `
  -SkipCisAssessment
```

`-SkipCisAssessment` is rejected for Production builds. A POC bundle created with this option contains `poc/images/security/CIS-ASSESSMENT-SKIPPED.txt` and must not be treated as security-assessed release evidence. Omit the switch for release/security-evidence builds.


## v1.16.16 runtime compatibility update

- Snyk now uses `/run/ai-sandbox-snyk`, a dedicated ephemeral `exec,nosuid,nodev` tmpfs, because the Snyk CLI downloads and executes a versioned native runtime from its cache. `/tmp` and `/var/tmp` remain `noexec`.
- When `-ReuseHardenedBase`/`--reuse-hardened-base` is used, the build refreshes only the immutable `UCODE_GIT_REF` from Databricks ucode `main`; the hardened Ubuntu base is still reused.
- The DevContainer Dockerfile fails the Admin build unless the pinned ucode commit supports `--profiles`, `--use-pat`, `--skip-validate`, and `--skip-upgrade`, preventing the old interactive-browser-login regression from reaching Developers.


### v1.16.16: Databricks SQL MCP and managed Tavily search policy

- Claude and Gemini receive an additional `databricks-sql` MCP registration. The wrapper fetches `<SSM_PREFIX>/databricks-sql-mcp-token` at runtime and connects to `${DATABRICKS_HOST}/api/2.0/mcp/sql`; the PAT is not stored in MCP settings.
- Tavily MCP calls are enforced by the root-owned `/etc/ai-sandbox/tavily-allowed-domains.json` policy. Search without `include_domains` is automatically constrained to the Admin allowlist; an out-of-policy domain is denied.
- Claude managed settings deny native `WebSearch`/`WebFetch`; Gemini system policy denies `google_web_search`/`web_fetch`. Developers cannot edit the system policy files because they are root-owned and the container root filesystem is read-only.
- To change the allowed Tavily domains, the Admin edits `.devcontainer/policies/tavily-allowed-domains.json`, rebuilds the image, and redistributes/redeploys it.
