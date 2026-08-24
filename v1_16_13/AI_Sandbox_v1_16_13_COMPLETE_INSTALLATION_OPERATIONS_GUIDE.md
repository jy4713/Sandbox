# AI Secure Sandbox v1.16.13 — Complete Installation, First-Run, Operations, MCP and Application Maintenance Guide

> **Package analyzed:** `AI_Sandbox_Admin_v1_16_13_SLIM_CLAUDE_DATABRICKS_MODEL_SERVICE.zip` and the matching `BUILD_ONLY_NO_DOCS` package. The runtime/build source is the same in both packages; the SLIM package additionally contains the `docs/` directory.
>
> **Primary platform:** Windows 365 / Windows 11 host + Docker Desktop + Linux DevContainer + Squid proxy.
>
> **Primary shell on Windows:** PowerShell 7.4+ (`pwsh`). Windows PowerShell 5.1 is intentionally unsupported by the package PowerShell entry points.
>
> **Important:** This guide documents the source package as shipped. It does not assume that a final DevContainer image has already been built, so tools whose versions are resolved at build time are marked accordingly in the version table.

---

# 0. Read this first — what you are installing

The package builds and distributes a secure AI development sandbox consisting of two runtime containers:

```text
Windows 365 / Windows 11
|
+-- VS Code UI
|
+-- Docker Desktop
|   |
|   +-- DevContainer
|   |   +-- Ubuntu 24.04 hardened runtime
|   |   +-- non-root vscode user (UID/GID 1000)
|   |   +-- read-only root filesystem
|   |   +-- Claude Code / Gemini CLI
|   |   +-- Databricks CLI + ucode
|   |   +-- Tavily CLI + Tavily MCP
|   |   +-- Snyk CLI + Snyk MCP
|   |   +-- AWS CLI / Azure CLI / Git / Python / Node.js
|   |   +-- SSM-aware wrappers and audit controls
|   |   `-- internal Docker network only
|   |
|   `-- Squid proxy
|       +-- internal Docker network
|       +-- external Docker network
|       +-- default deny
|       `-- explicit domain allowlist
|
+-- AWS bootstrap authentication
|   +-- static Access Key + Secret Key, OR
|   `-- IAM Identity Center / SSO fallback
|
`-- Host-visible logs
    +-- devcontainer logs
    `-- squid/access.log
```

The normal Developer does **not** need to manually retrieve Tavily, Snyk, Databricks, Claude, Gemini or ADO application secrets. Those application secrets are stored in AWS SSM Parameter Store and fetched only by the approved wrapper when the corresponding tool runs.

For the current demo focus, the important Databricks routes are:

```text
ucode claude
  +-- LLM/model request -> Databricks -> approved Claude model service
  +-- Tavily MCP        -> SSM -> Tavily
  `-- Snyk MCP          -> SSM -> Snyk

ucode gemini
  +-- LLM/model request -> Databricks -> approved Gemini model service
  +-- Tavily MCP        -> SSM -> Tavily
  `-- Snyk MCP          -> SSM -> Snyk
```

Bare `claude` and bare `gemini` are separate direct-provider routes. If corporate controls block the direct Anthropic/Google provider endpoints, use the Databricks `ucode` routes for the client demo.

---

# 1. Choose the package and deployment path

There are two Admin ZIP variants:

| Package | Runtime/build content | `docs/` | Recommended use |
|---|---:|---:|---|
| `BUILD_ONLY_NO_DOCS` | Same | No | Automated/internal build pipeline where documentation is stored separately |
| `SLIM` | Same | Yes | Admin workstation, review, demo preparation, manual operations |

There are also two distribution models:

| Mode | Image delivery | Hardened base path | Final image security assessment | Typical use |
|---|---|---|---|---|
| POC | TAR files | self-hardened Ubuntu 24.04/OpenSCAP path | Yes by default; can be explicitly skipped for fast iteration | Demo / proof of concept |
| Production | ECR immutable image release | Ubuntu Pro + USG | Required | Managed rollout |

For a client demo where you are building locally and transferring the images, use the **POC** path unless the environment has already moved to ECR.

---

# 2. Fresh Windows 365 host prerequisites

## 2.1 Required host software

Install/approve these on the Windows host before starting:

| Host component | Required | Why |
|---|---:|---|
| Windows 11 / Windows 365 Cloud PC | Yes | Host operating environment |
| Docker Desktop | Yes | Builds and runs Linux containers |
| Docker Compose v2 | Yes | Runtime two-container orchestration; normally included with Docker Desktop |
| PowerShell 7.4+ (`pwsh`) | Yes for `.ps1` workflows | All package PowerShell entry points declare PowerShell 7.4 |
| Git | Strongly recommended | Build provenance and ucode commit resolver |
| AWS CLI on host | Required for SSM/ECR/SSO setup | Admin SSM, ECR and browser-based SSO bootstrap |
| Python 3 on Admin host | Required only for application add/remove helper | `application-helper.py` |
| VS Code | Required for Developer experience | Dev Container attachment |
| Dev Containers extension | Required for VS Code Dev Container flow | Opens/attaches to `devcontainer` service |

Check them from **PowerShell 7**, not Windows PowerShell 5.1:

```powershell
$PSVersionTable.PSVersion
pwsh --version
docker version
docker compose version
git --version
aws --version
python --version
code --version
```

PowerShell must report at least `7.4.x`.

## 2.2 Docker Desktop settings

Use Linux containers. The package is not a Windows-container image.

Recommended checks:

```powershell
docker info --format '{{.OSType}}'
```

Expected:

```text
linux
```

Also verify Docker Desktop is fully started before build scripts are run:

```powershell
docker version
```

Both `Client` and `Server` sections must be returned. A client-only result means Docker Desktop/engine is not ready.

## 2.3 Do not weaken TLS or certificate checks

The build intentionally verifies HTTPS downloads and SHA-256 values. If corporate TLS inspection causes certificate errors, fix the trust chain or use an approved internal artifact mirror. Do **not** solve a first-build certificate issue by disabling certificate verification or changing the scripts to use insecure HTTP.

## 2.4 Recommended folder location

Use a short local path such as:

```text
C:\AI-Sandbox\v1.16.13\
```

Avoid extracting into a deeply nested OneDrive/SharePoint synchronized path for the first build. Long paths, on-access scanning and synchronization can make Docker build contexts and TAR operations slower and harder to diagnose.

---

# 3. Extract the Admin package and validate the source package

Example:

```powershell
New-Item -ItemType Directory -Force C:\AI-Sandbox\v1.16.13 | Out-Null
Expand-Archive `
  -Path .\AI_Sandbox_Admin_v1_16_13_SLIM_CLAUDE_DATABRICKS_MODEL_SERVICE.zip `
  -DestinationPath C:\AI-Sandbox\v1.16.13
```

Change into the extracted package root — the directory containing `.build.env.example`, `.env.example`, `scripts`, `.devcontainer`, `poc`, `ecr`, and `squid`.

Then run package lint **before making any configuration changes**:

```powershell
pwsh -NoProfile -File .\scripts\ci\lint-package.ps1
```

Expected final result:

```text
LINT PASSED: package is structurally valid.
```

If lint fails, do not build until the reported package source issue is corrected.

---

# 4. Understand the two configuration files before the first build

## 4.1 `.build.env` — Admin build configuration

`.build.env` controls versions, image references, downloaded artifact hashes, hardening inputs and release metadata. It is **not** a runtime secret file.

Create it:

```powershell
Copy-Item .build.env.example .build.env
```

Do not manually invent image SHA digests or download SHA-256 values. The supplied resolver scripts populate them.

### Every `.build.env` option

| Variable | Default/example | Required/condition | Meaning |
|---|---|---|---|
| `SANDBOX_VERSION` | `v1.16.13` | Yes | Package/runtime version stamped into image provenance |
| `RELEASE_TAG` | `v1.16.13` | Yes | Release tag used by Production publication |
| `DEVCONTAINER_TARGET` | `baseline` | Yes | Dockerfile target to build |
| `BASE_IMAGE` | Ubuntu 24.04 placeholder digest | Resolved before build | Final hardened base reference after hardening |
| `NODE_IMAGE` | Node 20 bookworm-slim placeholder digest | Resolved before build | Digest-pinned Node source stage |
| `SQUID_BASE_IMAGE` | Ubuntu placeholder initially | Resolved; must equal hardened `BASE_IMAGE` | Base for Squid image |
| `CLAUDE_CODE_VERSION` | `2.1.212` | Yes | Exact Claude Code npm version |
| `GEMINI_CLI_VERSION` | `0.53.0` | Yes | Exact Gemini CLI npm version |
| `TAVILY_CLI_VERSION` | `0.1.6` | Yes | Exact Tavily Python CLI version |
| `TAVILY_MCP_VERSION` | `0.2.21` | Yes | Exact Tavily MCP npm version |
| `SNYK_CLI_VERSION` | `1.1306.2` | Yes | Exact Snyk npm package version |
| `NPM_REGISTRY` | `https://registry.npmjs.org` | Yes | Approved npm registry/mirror |
| `AWSCLI_URL` | AWS CLI v2 Linux ZIP URL | Yes | AWS CLI archive source |
| `AWSCLI_SHA256` | placeholder | Must be 64 hex chars | Resolved hash of AWS CLI ZIP |
| `DATABRICKS_CLI_VERSION` | `1.10.0` | Yes | Exact Databricks CLI version |
| `DATABRICKS_CLI_URL` | v1.10.0 release ZIP | Yes | Immutable Databricks CLI source |
| `DATABRICKS_CLI_SHA256` | placeholder | Must be 64 hex chars | Resolved hash of Databricks CLI ZIP |
| `UCODE_GIT_REF` | placeholder | Must become 40 hex chars | Immutable Databricks ucode commit |
| `SSG_VERSION` | `0.1.80` | Yes | ComplianceAsCode content version |
| `SSG_URL` | 0.1.80 release ZIP | Yes | OpenSCAP content source |
| `SSG_SHA256` | placeholder | Must be 64 hex chars | Resolved SSG ZIP hash |
| `CIS_PROFILE_ID` | CIS Level 1 Server profile | Yes | OpenSCAP profile ID |
| `REQUIRE_CIS_PASS` | `false` | POC; Production forces strict behavior | Controls whether assessment failure gates build where supported |
| `GCM_VERSION` | `2.5.0` | Yes | Git Credential Manager version |
| `GCM_SHA256` | blank initially | Resolver can populate | GCM package hash |
| `MAX_CRITICAL_FINDINGS` | `0` | Production/security gate | Allowed critical findings threshold |
| `MAX_HIGH_FINDINGS` | `0` | Production/security gate | Allowed high findings threshold |
| `REQUIRE_IMAGE_SIGNING` | `false` | Environment-dependent | Whether image signing is enforced |
| `COSIGN_KEY_REF` | AWS KMS alias example | If signing enabled | Cosign signing key reference |
| `PUBLISH_APPROVED_MANIFEST_TO_SSM` | `true` | Production | Publishes approved immutable ECR image manifest to SSM |
| `SSM_PREFIX` | `/sandbox` | Yes | SSM namespace |
| `APPROVED_IMAGES_SSM_PARAMETER` | blank | Optional | Override approved image manifest SSM parameter |
| `DEVELOPER_AWS_PROFILE` | `sandbox` | SSO fallback distribution | Default profile stamped into Developer template |
| `DEVELOPER_AWS_REGION` | `eu-west-2` | Yes | Developer AWS region default |
| `DEVELOPER_AWS_SSO_SESSION` | `sandbox` | SSO fallback | IAM Identity Center session name |
| `DEVELOPER_AWS_SSO_START_URL` | placeholder | SSO fallback only | Company Identity Center start URL |
| `DEVELOPER_AWS_SSO_REGION` | placeholder | SSO fallback only | Identity Center region |
| `DEVELOPER_AWS_SSO_ACCOUNT_ID` | placeholder | SSO fallback only | 12-digit account ID |
| `DEVELOPER_AWS_SSO_ROLE_NAME` | placeholder | SSO fallback only | Permission set/role name |

## 4.2 `.env` — Developer runtime configuration

`.env` is separate from `.build.env` and is created in the runtime/Developer package.

Create it when required:

```powershell
Copy-Item .env.example .env
```

### Every `.env` option

| Variable | Default/example | Required/condition | Meaning |
|---|---|---|---|
| `DATABRICKS_HOST` | workspace URL placeholder | Required for `ucode`/Databricks | Approved Databricks workspace URL; HTTPS, no trailing slash |
| `DATABRICKS_CLAUDE_MODEL` | `system.ai.claude-sonnet-4-5` | Required for `ucode claude` | Approved Databricks Claude model/service |
| `DATABRICKS_GEMINI_MODEL` | `system.ai.gemini-3-1-flash-lite` | Required for `ucode gemini` | Approved Databricks Gemini model/service |
| `SANDBOX_AWS_PROFILE` | `sandbox` | Yes | Named profile used for SSO/compatibility configuration |
| `SSM_PREFIX` | `/sandbox` | Yes | Parameter Store prefix |
| `AWS_REGION` | `eu-west-2` | Yes | STS/SSM/ECR region |
| `AWS_ACCESS_KEY_ID` | blank | Optional static mode | AWS bootstrap access key; must be paired with secret key |
| `AWS_SECRET_ACCESS_KEY` | blank | Optional static mode | AWS bootstrap secret key; must be paired with access key |
| `AWS_SESSION_TOKEN` | blank | Optional | Required only if using temporary static credentials |
| `AWS_SSO_SESSION` | `sandbox` | Required only for SSO fallback | Identity Center session name |
| `AWS_SSO_START_URL` | placeholder | Required only for SSO fallback | IAM Identity Center portal URL |
| `AWS_SSO_REGION` | placeholder | Required only for SSO fallback | Identity Center region |
| `AWS_SSO_ACCOUNT_ID` | placeholder | Required only for SSO fallback | 12-digit account ID |
| `AWS_SSO_ROLE_NAME` | placeholder | Required only for SSO fallback | Permission-set role |
| `DEVELOPER_ID` | `yourname` | Must be changed | Audit attribution |
| `SANDBOX_AUDIT_REQUIRED` | `true` | Recommended/expected | Fail closed when required audit destination is unavailable |
| `SANDBOX_CONTENT_LOGGING` | `false` | Optional | Enables sensitive prompt/response content logging only when explicitly approved |
| `SNYK_API` | blank | Optional | Override Snyk SaaS/API endpoint |
| `HIDDENLAYER_API_URL` | blank | Only if HiddenLayer used | Approved HiddenLayer HTTPS base URL |
| `SANDBOX_LOG_ROOT` | blank | Optional | Host log root; defaults to package-local location |
| `APPROVED_IMAGES_SSM_PARAMETER` | blank | Production optional | Override centrally managed approved-image manifest parameter |

Never put these application secrets directly into `.env`:

```text
ANTHROPIC_API_KEY
GEMINI_API_KEY
DATABRICKS_TOKEN
ADO_PAT
TAVILY_API_KEY
SNYK_TOKEN
HIDDENLAYER_CLIENT_SECRET
```

They belong in SSM.

---

# 5. First build — resolve image digests and downloadable artifact hashes

This is the stage that commonly produces what people describe as a "digest error", checksum error, or unresolved `REPLACE_...` value.

## 5.1 Recommended manual first-build sequence

From the package root:

```powershell
Copy-Item .build.env.example .build.env

pwsh -NoProfile -File .\scripts\supply-chain\resolve-base-digests.ps1 -Write

pwsh -NoProfile -File .\scripts\supply-chain\resolve-tool-artifacts.ps1 -Write
```

Then check that placeholders are gone:

```powershell
Select-String -Path .\.build.env -Pattern 'REPLACE_|<company>|<identity-center-region>|<12-digit-account-id>|<sandbox-developer-permission-set-role>'
```

The SSO placeholders may remain if you will use static AWS credentials at runtime. The build-time digest/hash placeholders must not remain.

Check the key immutable fields:

```powershell
Get-Content .\.build.env | Select-String 'BASE_IMAGE=|NODE_IMAGE=|AWSCLI_SHA256=|DATABRICKS_CLI_SHA256=|SSG_SHA256=|GCM_SHA256=|UCODE_GIT_REF='
```

Expected patterns:

```text
...@sha256:<64 hex>
AWSCLI_SHA256=<64 hex>
DATABRICKS_CLI_SHA256=<64 hex>
SSG_SHA256=<64 hex>
UCODE_GIT_REF=<40 hex>
```

## 5.2 You can also let `build-sandbox.ps1` do this

The top-level build command automatically creates `.build.env` if missing, resolves external inputs, builds the hardened base, then builds the final images.

```powershell
pwsh -NoProfile -File .\scripts\admin\build-sandbox.ps1 -SandboxType POC
```

For the first build, the explicit resolver sequence is still useful because it isolates network/supply-chain problems from hardening and image-build problems.

---

# 6. POC installation/build — detailed end-to-end procedure

## 6.1 Step 1 — source/package lint

```powershell
pwsh -NoProfile -File .\scripts\ci\lint-package.ps1
```

Do not continue on `LINT FAILED`.

## 6.2 Step 2 — build configuration

```powershell
Copy-Item .build.env.example .build.env
```

Review tool versions, Databricks-related defaults, SSO distribution defaults and security gate values.

## 6.3 Step 3 — resolve digests/hashes

```powershell
pwsh -NoProfile -File .\scripts\supply-chain\resolve-base-digests.ps1 -Write
pwsh -NoProfile -File .\scripts\supply-chain\resolve-tool-artifacts.ps1 -Write
```

## 6.4 Step 4 — build the POC

Normal release/evidence build:

```powershell
pwsh -NoProfile -File .\scripts\admin\build-sandbox.ps1 -SandboxType POC
```

Fast iterative build reusing an already validated hardened base:

```powershell
pwsh -NoProfile -File .\scripts\admin\build-sandbox.ps1 `
  -SandboxType POC `
  -ReuseHardenedBase
```

Reuse previous `.build.env` automatically:

```powershell
pwsh -NoProfile -File .\scripts\admin\build-sandbox.ps1 `
  -SandboxType POC `
  -ReuseHardenedBase `
  -BuildEnvSource 'C:\path\to\previous-v1.16.x\.build.env'
```

Fast POC development only — skip final CIS assessment:

```powershell
pwsh -NoProfile -File .\scripts\admin\build-sandbox.ps1 `
  -SandboxType POC `
  -ReuseHardenedBase `
  -SkipCisAssessment
```

Do not use a `-SkipCisAssessment` build as security-assessed release evidence.

## 6.5 Step 5 — expected POC outputs

The POC build creates `poc/images/` containing the image TARs and integrity metadata, including:

```text
poc/images/
+-- sandbox-devcontainer.tar
+-- sandbox-squid.tar
+-- image-manifest.json
+-- image-manifest.env
+-- runtime-policy.sha256
+-- SHA256SUMS
`-- security/...                 # assessment evidence or skip marker
```

## 6.6 Step 6 — export a Developer package

Include the generated POC image TARs:

```powershell
pwsh -NoProfile -File .\scripts\admin\export-developer-packages.ps1 -IncludePocImages
```

Custom output directory:

```powershell
pwsh -NoProfile -File .\scripts\admin\export-developer-packages.ps1 `
  -OutputDirectory 'C:\AI-Sandbox\DeveloperPackages' `
  -IncludePocImages
```

The POC Developer package contains only the runtime/start files needed by the Developer; Admin build scripts are not required on the Developer machine.

---

# 7. Developer POC first start — detailed procedure

## 7.1 Copy the Developer package locally

Example:

```text
C:\AI-Sandbox\Developer\
```

The Developer POC root should contain `.env.example`, `.devcontainer`, `poc`, `scripts`, `workspace` and the Developer guide.

## 7.2 Create `.env`

```powershell
Copy-Item .env.example .env
```

At minimum for the Databricks demo, set:

```env
DATABRICKS_HOST=https://<approved-workspace-host>
DATABRICKS_CLAUDE_MODEL=<approved-claude-model-service>
DATABRICKS_GEMINI_MODEL=<approved-gemini-model-service>
AWS_REGION=eu-west-2
SSM_PREFIX=/sandbox
DEVELOPER_ID=<developer-id>
```

Then choose **one** AWS authentication mode.

### Option A — static bootstrap credentials

```env
AWS_ACCESS_KEY_ID=<runtime access key>
AWS_SECRET_ACCESS_KEY=<runtime secret key>
AWS_SESSION_TOKEN=<only if temporary credentials require one>
```

Leave SSO fields unused/placeholder if static credentials are complete.

### Option B — IAM Identity Center / SSO fallback

Leave the three static credential values blank and configure:

```env
AWS_SSO_SESSION=sandbox
AWS_SSO_START_URL=https://<company>.awsapps.com/start
AWS_SSO_REGION=<identity-center-region>
AWS_SSO_ACCOUNT_ID=<12-digit-account-id>
AWS_SSO_ROLE_NAME=<approved-role>
```

A partial static pair is intentionally rejected. Do not set only `AWS_ACCESS_KEY_ID` or only `AWS_SECRET_ACCESS_KEY`.

## 7.3 Verify required SSM parameters exist

For the current package, the key names are:

```text
/sandbox/claude-api-key
/sandbox/gemini-api-key
/sandbox/databricks-token
/sandbox/ado-org
/sandbox/ado-project
/sandbox/ado-repo
/sandbox/ado-pat
/sandbox/tavily-api-key
/sandbox/snyk-token
/sandbox/hiddenlayer-client-id
/sandbox/hiddenlayer-client-secret
```

For a Databricks + Tavily + Snyk demo, the minimum relevant application secrets are normally:

```text
/sandbox/databricks-token
/sandbox/tavily-api-key
/sandbox/snyk-token
```

Do not display secret values. To verify names/types only:

```powershell
aws ssm get-parameters-by-path `
  --path /sandbox `
  --region eu-west-2 `
  --query 'Parameters[*].{Name:Name,Type:Type}' `
  --output table
```

## 7.4 Load and start

From PowerShell 7:

```powershell
pwsh -NoProfile -File .\scripts\poc\load-and-start.ps1
```

The script performs five important stages:

```text
1. Verify bundle SHA256SUMS
2. Verify runtime-policy hashes
3. docker load approved DevContainer/Squid TARs
4. Verify loaded image IDs against the manifest
5. docker compose up -d --force-recreate
```

It also validates `.env` before container start.

## 7.5 Check container status

```powershell
docker compose -f .\poc\docker-compose.yml ps
```

Expected:

```text
squid-proxy   running/healthy
devcontainer  running
```

## 7.6 Attach VS Code

Open the Developer package folder in VS Code and use Dev Containers to reopen/attach to the running `devcontainer` service.

The configured workspace inside the container is:

```text
/home/vscode/workspace
```

The host `workspace/` directory is bind-mounted there, so source files survive container recreation and Windows restart as long as the host folder remains.

## 7.7 Post-create behavior

When VS Code runs the Dev Container `postCreateCommand`, `/usr/local/bin/post-create` prepares runtime state including AWS profile compatibility/SSO configuration, Git settings, MCP definitions and runtime checks.

If the container was started only with Compose and the Dev Container lifecycle was not run, you can manually check/initialize MCP with:

```bash
configure-mcp
```

After v1.16.13, `ucode claude`/`ucode gemini` also configure MCP automatically inside their own temporary HOME, so the Developer does not need to manually register Tavily/Snyk for Databricks-routed sessions.

## 7.8 Runtime verification

Inside the DevContainer:

```bash
verify-runtime
```

From the Windows host:

```powershell
pwsh -NoProfile -File .\scripts\poc\verify-sandbox.ps1 -Path poc
```

These checks are different:

- `verify-runtime` validates security/runtime invariants from inside the DevContainer.
- `verify-sandbox.ps1` validates the running Compose stack, egress behavior, proxy bypass resistance, host logs and runtime verification.

---

# 8. Databricks + Tavily/Snyk MCP test procedure

## 8.1 Direct MCP registration check

Inside the container:

```bash
claude mcp list
gemini mcp list
```

Expected definitions include:

```text
tavily -> /usr/local/bin/tavily-mcp-ssm
snyk   -> /usr/local/bin/snyk-mcp-ssm
```

`Connected` means the MCP stdio server handshake succeeds. It does not, by itself, prove that every real search/scan request succeeds.

## 8.2 Why Gemini MCP has explicit AWS env references

Gemini sanitizes secret-looking inherited variables for MCP subprocesses. The v1.16.12+ `configure-mcp` logic therefore writes references — not secret values — for the AWS bootstrap variables:

```json
"env": {
  "AWS_ACCESS_KEY_ID": "$AWS_ACCESS_KEY_ID",
  "AWS_SECRET_ACCESS_KEY": "$AWS_SECRET_ACCESS_KEY",
  "AWS_SESSION_TOKEN": "$AWS_SESSION_TOKEN",
  "SANDBOX_AWS_PROFILE": "$SANDBOX_AWS_PROFILE",
  "AWS_REGION": "$AWS_REGION"
}
```

This lets `/usr/local/bin/tavily-mcp-ssm` and `/usr/local/bin/snyk-mcp-ssm` authenticate to SSM while avoiding persistence of actual AWS credential values in Gemini settings.

## 8.3 Databricks-routed Claude

Run:

```bash
ucode claude
```

Internally, the wrapper:

```text
SSM /sandbox/databricks-token
 -> temporary HOME
 -> temporary .databrickscfg
 -> ucode configure --profiles DEFAULT --use-pat --skip-validate --skip-upgrade
 -> configure-mcp inside temporary HOME
 -> approved Databricks Claude model forced if Developer did not specify --model
 -> Claude starts through Databricks
```

Inside Claude:

```text
/mcp
```

Then test:

```text
Use Tavily MCP to search IMDb for Interstellar.
```

And for Snyk:

```text
Use Snyk MCP to scan the current project for dependency vulnerabilities and summarise the results.
```

## 8.4 Databricks-routed Gemini

Run:

```bash
ucode gemini
```

Inside Gemini:

```text
/mcp list
```

Then request Tavily explicitly, for example:

```text
Use the Tavily MCP tool to search IMDb for Interstellar. Return the title, release year and IMDb URL.
```

The expected route is:

```text
Gemini agent through Databricks
   -> MCP stdio
   -> tavily-mcp-ssm
   -> AWS SSM /sandbox/tavily-api-key
   -> Tavily API through Squid
```

## 8.5 Existing direct Tavily test remains available

The v1.16.13 MCP additions do not remove the existing CLI troubleshooting path:

```bash
tvly search "Interstellar IMDb"
```

This is useful for separating "Tavily API/SSM connectivity works" from "AI agent MCP integration works".

---

# 9. Production / ECR installation path

Production uses the same final DevContainer/Squid concepts but publishes immutable image digests to ECR instead of handing Developers TAR files.

## 9.1 Required Admin environment

Typical values include:

```powershell
$env:ECR_REGISTRY = '<account>.dkr.ecr.eu-west-2.amazonaws.com'
$env:AWS_REGION = 'eu-west-2'
$env:UBUNTU_PRO_TOKEN = '<approved Ubuntu Pro token>'
```

Use the correct Admin AWS identity/profile for ECR repository management and publication.

## 9.2 Build

```powershell
pwsh -NoProfile -File .\scripts\admin\build-sandbox.ps1 -SandboxType Production
```

If a previously validated Production hardened base is reusable:

```powershell
pwsh -NoProfile -File .\scripts\admin\build-sandbox.ps1 `
  -SandboxType Production `
  -ReuseHardenedBase
```

A valid reused Production hardened base does not require a new Ubuntu Pro hardening run. If reuse validation fails, the script automatically falls back to a full rebuild and then requires the Ubuntu Pro token.

`-SkipCisAssessment` is rejected for Production.

## 9.3 Production Developer package

```powershell
pwsh -NoProfile -File .\scripts\admin\export-developer-packages.ps1
```

The Production Developer package uses `scripts/ecr/pull-and-start.ps1`. It authenticates to AWS, resolves the centrally approved immutable image manifest, pulls approved ECR images, retags them to local `sandbox/approved-*` tags and starts Compose with `pull_policy: never`.

---

# 10. Complete command-option reference

## 10.1 `scripts/admin/build-sandbox.ps1`

| Option | Type | Default | Meaning |
|---|---|---|---|
| `-SandboxType` | string, mandatory | none | `POC` selects self-hardening; non-POC values select Production/Ubuntu Pro + USG behavior |
| `-UbuntuProToken` | string | `$env:UBUNTU_PRO_TOKEN` | Needed only when a non-POC hardened base must actually be rebuilt |
| `-ReuseHardenedBase` | switch | off | Reuses the exact previously validated hardened digest if labels/profile match; otherwise automatically falls back to full build |
| `-SkipCisAssessment` | switch | off | POC only; skips final DevContainer OpenSCAP assessment |
| `-BuildEnvSource` | string | empty | Copies an existing `.build.env` into the current package before validation/reuse |

Bash equivalents:

```text
build-sandbox.sh <SandboxType> [UbuntuProToken]
  --reuse-hardened-base
  --skip-cis-assessment
  --build-env-source PATH
  --ubuntu-pro-token VALUE
  -h / --help
```

## 10.2 `scripts/admin/export-developer-packages.ps1`

| Option | Meaning |
|---|---|
| `-OutputDirectory <path>` | Override default `developer-packages` output folder |
| `-IncludePocImages` | Copy generated POC TAR/evidence bundle into the POC Developer package |

## 10.3 `scripts/supply-chain/resolve-base-digests.ps1`

| Option | Default | Meaning |
|---|---|---|
| `-Write` | off | Persist resolved digests into `.build.env`; otherwise only print them |
| `-UbuntuRef` | `ubuntu:24.04` | Upstream Ubuntu reference to resolve |
| `-NodeRef` | `node:20-bookworm-slim` | Upstream Node image to resolve |

## 10.4 `scripts/supply-chain/resolve-tool-artifacts.ps1`

| Option | Meaning |
|---|---|
| `-Write` | Persist resolved artifact hashes and ucode commit to `.build.env` |
| `-UcodeOnly` | Refresh only immutable `UCODE_GIT_REF`; used during hardened-base reuse |

## 10.5 `scripts/hardening/build-hardened-base.ps1`

| Option | Default | Meaning |
|---|---|---|
| `-SandboxType` | mandatory | `POC` or Production-style hardening path |
| `-UbuntuProToken` | `$env:UBUNTU_PRO_TOKEN` | Ubuntu Pro token for Production hardening |
| `-SourceImage` | `ubuntu:24.04` | Starting image; normally use resolver-generated digest |
| `-Registry` | empty | Optional shared registry for hardened base digest; otherwise local scratch registry is used |
| `-ImageRepoName` | `ai-sandbox-hardened-base` | Hardened image repository name |
| `-Tag` | empty | Optional custom tag |
| `-SsgUrl` | empty | Override ComplianceAsCode content source |
| `-SsgSha256` | empty | Override ComplianceAsCode hash |
| `-ComplianceDataStreamPath` | empty | Use an existing local data stream instead of downloading |
| `-BuildEnvFile` | empty | Override build-env path |
| `-WorkDir` | `hardened-base-build` | Hardened-base working directory |
| `-SkipPush` | off | Build/commit locally only; result will not be usable as digest-pinned base without a registry digest |
| `-LocalRegistryPort` | `5000` | Scratch registry port |
| `-KeepContainers` | off | Keep intermediate hardening containers for investigation |
| `-RefreshComplianceContent` | off | Downloads latest ComplianceAsCode content; breaks normal pinning and is only for local experiments |

## 10.6 `scripts/poc/build-and-export.ps1`

| Option | Meaning |
|---|---|
| `-SkipCisAssessment` | Skip final DevContainer OpenSCAP assessment; POC/test only |

## 10.7 `scripts/poc/load-and-start.ps1`

No user parameters. It reads package paths and `.env` from the Developer package root and fails closed on missing/tampered bundle files or invalid runtime configuration.

## 10.8 `scripts/poc/verify-sandbox.ps1`

| Option | Allowed values | Default | Meaning |
|---|---|---|---|
| `-Path` | `poc`, `ecr` | `poc` | Select Compose definition to verify |

## 10.9 `scripts/platform/01-setup-ssm.ps1`

No command-line parameters. It uses environment overrides:

| Environment variable | Default | Meaning |
|---|---|---|
| `SSM_PREFIX` | `/sandbox` | Parameter namespace |
| `AWS_REGION` | `eu-west-2` | AWS region |
| `SSM_KMS_KEY_ID` | `alias/aws/ssm` | KMS key for SecureString parameters |

## 10.10 `scripts/platform/02-setup-ecr.ps1`

No command-line parameters. Important environment inputs include `ECR_REGISTRY`, `AWS_REGION` and the loaded `.build.env` values.

## 10.11 `scripts/platform/03-setup-logging.ps1`

| Option | Allowed/default | Meaning |
|---|---|---|
| `-Mode` | `AMA`, `LogsIngestionApi`, `None`; default `None` | Select host-side log-forwarding preparation mode |
| `-LogRoot` | `C:\ProgramData\AI-Sandbox\Logs` | Host log root |

## 10.12 `scripts/ecr/deploy-ecr.ps1`

| Option | Default | Meaning |
|---|---|---|
| `-Target` | `C:\ai-sandbox` | Target Production runtime folder |
| `-HostLogRoot` | `C:\ProgramData\AI-Sandbox\Logs` | Host log directory |

## 10.13 `scripts/ecr/pull-and-start.ps1`

| Option | Default | Meaning |
|---|---|---|
| `-SandboxDir` | package root derived from script path | Override Production Developer package root |

## 10.14 `scripts/security/assess-cis-l1.ps1`

| Option | Default | Meaning |
|---|---|---|
| `-Image` | `sandbox/devcontainer:v1` | Image to assess |
| `-ReportDir` | script/environment-derived | Output folder for OpenSCAP evidence |

## 10.15 Logging sender options

`send-logs-ingestion.ps1` options:

| Option | Required/default | Meaning |
|---|---|---|
| `-LogRoot` | default `C:\ProgramData\AI-Sandbox\Logs` | Local exported log root |
| `-Endpoint` | mandatory | Azure Monitor Logs Ingestion endpoint |
| `-DcrImmutableId` | mandatory | DCR immutable ID |
| `-StreamName` | `Custom-AISandboxHostLogs` | DCR stream |
| `-TenantId` | mandatory | Entra tenant ID |
| `-ClientId` | mandatory | App/client ID |
| `-ClientSecret` | `$env:AZURE_CLIENT_SECRET` | Optional direct secret input |
| `-ClientSecretSsmParameter` | optional | Retrieve sender secret from SSM instead |
| `-AwsProfile` | `sandbox` | AWS profile for SSM retrieval |
| `-AwsRegion` | `eu-west-2` | AWS region |
| `-StateFile` | optional | Sender state/checkpoint file |
| `-BatchSize` | `200`, allowed 1–1000 | Maximum batch records |

## 10.16 Application helper options

PowerShell add helper:

```powershell
.\scripts\applications\add-application.ps1 `
  -Name <name> `
  -Command <command> `
  -InstallType <npm|uv|apt|archive|custom> `
  [other options]
```

| Option | Required | Meaning |
|---|---:|---|
| `-Name` | Yes | Stable lower-case application identifier |
| `-Command` | Yes | Public command name |
| `-InstallType` | Yes | `npm`, `uv`, `apt`, `archive`, or `custom` |
| `-Package` | Type-dependent | npm/Python/apt package name |
| `-Version` | Strongly recommended/required for pinned package installs | Exact approved version |
| `-Url` | Archive/custom | HTTPS artifact URL |
| `-Sha256` | Archive/direct download | Approved artifact SHA-256 |
| `-ArchiveFormat` | Archive type | `binary`, `zip`, `tar.gz` |
| `-BinaryPath` | Archive when needed | Executable path inside extracted archive |
| `-CustomSnippet` | Custom install | Reviewed Dockerfile installation snippet |
| `-SecretEnv` | Secret-backed app | Environment variable presented to child process |
| `-SsmParameter` | Secret-backed app | SSM parameter suffix/name |
| `-Egress` | Networked app | Approved domain entry for Squid |
| `-ConfigDir` | If persistent writable state required | Narrow writable config directory |
| `-Mcp` | Optional switch | Add MCP integration scaffolding |
| `-McpSubcommand` | Optional | MCP subcommand if vendor CLI exposes MCP through a subcommand |
| `-Apply` | No | Without it, helper is preview-only; with it, source changes are written |

Remove helper:

```powershell
.\scripts\applications\remove-application.ps1 -Name <name> [-Apply]
```

Validate helper:

```powershell
.\scripts\applications\validate-application.ps1 -Name <name> [-RunLint]
```

## 10.17 ADO helper options

`ado-pr-create.ps1` supports `-Org`, `-Project`, `-Repo`, `-Title`, `-Source`, `-Target` (default `main`), `-Description`, `-Reviewers`, `-Draft`, `-AutoComplete`, and `-Auth pat|az`.

`ado-trigger.ps1` supports `-Org`, `-Project`, `-PipelineId`, `-Branch` (default `main`), `-Params` (default `{}`), `-Wait`, and `-Auth pat|az`.

---

# 11. First-run errors and how to handle them

This section is intentionally ordered by the stage at which the failure normally appears.

## 11.1 `#Requires -Version 7.4` / PowerShell version error

**Symptom**

```text
The script requires PowerShell 7.4...
```

or the script works differently in `powershell.exe`.

**Cause**: Windows PowerShell 5.1 was used.

**Fix**:

```powershell
pwsh --version
pwsh -NoProfile -File .\scripts\ci\lint-package.ps1
```

Do not edit out the version requirement.

## 11.2 Script execution blocked / Mark of the Web

If the ZIP came from a browser/download system, Windows may mark files as downloaded content.

First verify that the package is the approved package. Then use the normal PowerShell 7 `-File` invocation. If your organisation permits file unblocking, unblock only the approved extracted package rather than lowering machine-wide execution policy. Do not set a broad `Unrestricted` policy just to run the package.

## 11.3 `docker` command not found / cannot connect to Docker engine

**Checks**:

```powershell
docker version
docker context ls
docker info
```

Start Docker Desktop and wait for the Linux engine. Confirm `docker info --format '{{.OSType}}'` returns `linux`.

## 11.4 WSL2/virtualisation/Docker Desktop startup error

This is a host issue, not a Sandbox package issue. Resolve Docker Desktop/Windows 365 policy, WSL2 and virtualisation prerequisites before running build scripts. Do not modify the Sandbox Dockerfiles to work around an unavailable Docker engine.

## 11.5 `.build.env not found`

**Fix**:

```powershell
Copy-Item .build.env.example .build.env
```

Then run both resolvers.

## 11.6 `REPLACE_...`, invalid digest, or `must be 64 hex chars`

This is the common **digest/checksum first-build error**.

Run:

```powershell
pwsh -NoProfile -File .\scripts\supply-chain\resolve-base-digests.ps1 -Write
pwsh -NoProfile -File .\scripts\supply-chain\resolve-tool-artifacts.ps1 -Write
```

Do not paste a guessed SHA. Re-run the resolver against the approved source.

## 11.7 Docker manifest/digest resolution fails

Possible causes:

- Docker is not authenticated to a required registry.
- Corporate firewall/proxy blocks the registry.
- Upstream image reference is unavailable.
- Docker Desktop is not using the expected network/proxy configuration.

Test the upstream references explicitly:

```powershell
docker pull ubuntu:24.04
docker pull node:20-bookworm-slim
```

If corporate policy requires an internal registry mirror, change the approved base references and resolver inputs rather than bypassing the control.

## 11.8 TLS/certificate error while downloading AWS CLI, Databricks CLI, GCM, SSG, Azure CLI or uv

Do **not** add insecure flags. Resolve the enterprise root CA/trust or use an approved internal mirror. Any direct-download artifact that is expected to be hashed must still be validated against the approved SHA-256.

## 11.9 `SHA256 mismatch`

There are two different places this can occur.

### During image build

The downloaded artifact no longer matches `.build.env`. Re-resolve only after confirming that the upstream version/source is still approved:

```powershell
pwsh -NoProfile -File .\scripts\supply-chain\resolve-tool-artifacts.ps1 -Write
```

### During POC Developer load

`load-and-start.ps1` verifies `poc/images/SHA256SUMS`. A mismatch means the delivered bundle changed or was corrupted. Do not bypass the check. Re-copy/re-export the approved bundle.

## 11.10 `BASE_IMAGE and SQUID_BASE_IMAGE must be identical hardened digests`

The final DevContainer and Squid are expected to derive from the same hardened base. Run the full top-level build or the hardened-base builder so `hardened-base.env` is applied back into `.build.env`. Do not manually point Squid to a different unhardened Ubuntu digest.

## 11.11 Hardened-base reuse is rejected

`-ReuseHardenedBase` is deliberately fail-safe. Reuse is rejected if:

- `.build.env` is incomplete.
- `BASE_IMAGE != SQUID_BASE_IMAGE`.
- exact digest cannot be found/pulled.
- `hardening.method` label does not match POC/Production.
- `hardening.profile` is not `cis_level1_server`.

The top-level script automatically falls back to the full resolver/hardening path. This is expected behavior.

## 11.12 Ubuntu Pro token required

Production hardened-base rebuild needs `-UbuntuProToken` or `$env:UBUNTU_PRO_TOKEN`.

```powershell
$env:UBUNTU_PRO_TOKEN='<approved token>'
pwsh -NoProfile -File .\scripts\admin\build-sandbox.ps1 -SandboxType Production
```

A valid reused Production hardened base does not need to re-run hardening.

## 11.13 ucode commit/headless PAT capability error

The package pins ucode to an immutable Git commit and tests that the build supports:

```text
--profiles
--use-pat
--skip-validate
--skip-upgrade
```

If this fails, do not remove the guard. Re-resolve `UCODE_GIT_REF` and rebuild:

```powershell
pwsh -NoProfile -File .\scripts\supply-chain\resolve-tool-artifacts.ps1 -Write -UcodeOnly
```

## 11.14 CIS/OpenSCAP assessment failure

For a release/evidence build, investigate the assessment report under `security/reports` or the configured report directory. `-SkipCisAssessment` exists only for POC iteration and must not be used to conceal a release-security failure.

## 11.15 Squid fails immediately with a FATAL ACL/domain overlap

Squid `dstdomain` uses `.domain.com` to cover both the apex and subdomains. Do not list both:

```text
.domain.com
domain.com
```

or use invalid `*.domain.com` syntax.

Run package lint after editing `squid/whitelist.txt`:

```powershell
pwsh -NoProfile -File .\scripts\ci\lint-package.ps1
```

## 11.16 `.env` created, configure runtime values and rerun

`load-and-start.ps1` creates `.env` from the template if it does not exist and then stops so you can review it. This is intentional. Fill the required values, then run the script again.

## 11.17 `DEVELOPER_ID is missing or still a placeholder`

Set:

```env
DEVELOPER_ID=<approved developer identifier>
```

This is used for audit attribution.

## 11.18 Partial static AWS credentials error

If you configure static mode, both must be set:

```env
AWS_ACCESS_KEY_ID=...
AWS_SECRET_ACCESS_KEY=...
```

Do not set only one. If `AWS_SESSION_TOKEN` is set, the access/secret pair must also be present.

## 11.19 SSO fallback placeholder error

If static credentials are blank, the launcher requires non-placeholder SSO values. Configure the Identity Center start URL, region, 12-digit account ID and approved role.

## 11.20 AWS `AccessDenied` for SSM

The AWS bootstrap identity needs only the approved SSM permissions required to read the Sandbox namespace. Confirm identity without exposing secrets:

```bash
aws sts get-caller-identity --region eu-west-2
```

Then verify parameter names/types, not values:

```bash
aws ssm get-parameters-by-path \
  --path /sandbox \
  --region eu-west-2 \
  --query 'Parameters[*].{Name:Name,Type:Type}' \
  --output table
```

## 11.21 `DATABRICKS_HOST must use https://`

Use the full approved workspace URL with `https://`. Also ensure the exact hostname is present in `squid/whitelist.txt` at image-build time.

## 11.22 `DATABRICKS_CLAUDE_MODEL is required` / `DATABRICKS_GEMINI_MODEL is required`

Set the approved model service names in `.env`. The ucode wrappers intentionally fail closed rather than selecting an arbitrary model.

## 11.23 Databricks endpoint returns 403/401

Check in this order:

```text
AWS auth -> SSM databricks-token retrieval -> DATABRICKS_HOST -> PAT validity -> model/service entitlement -> Squid allowlist
```

Use `sandbox-info` for non-secret configuration display. Do not print the Databricks token.

## 11.24 `claude mcp list` works but `gemini mcp list` shows Disconnected

In this package, Gemini MCP needs explicit AWS bootstrap env **references** because Gemini sanitizes inherited secret-looking variables. v1.16.12+ `configure-mcp` contains this fix. Run:

```bash
configure-mcp
gemini mcp list
```

Then inspect the config safely:

```bash
jq '.mcpServers.tavily' ~/.gemini/settings.json
```

You should see `$AWS_ACCESS_KEY_ID`, `$AWS_SECRET_ACCESS_KEY`, etc. as literal references — not real values.

## 11.25 `ucode claude` / `ucode gemini` has no Tavily/Snyk MCP

This was the temporary-HOME propagation issue addressed in **v1.16.13**. Rebuild/reload the v1.16.13 DevContainer image. The wrapper now runs `configure-mcp` automatically inside each ucode temporary HOME.

Do not manually copy the entire persistent `.claude` or `.gemini` directory into the temporary ucode HOME; that could copy unrelated user state/cache.

## 11.26 Gemini messages that look like errors but MCP is Connected

With the pinned Gemini CLI version, messages such as these can appear:

```text
Timeout of 30000 exceeds the interval of 10000. Clamping timeout to interval duration.
The 'metricReader' option is deprecated. Please use 'metricReaders' instead.
[TELEMETRY] GEMINI_MEMORY_MONITOR_INTERVAL: undefined
```

If `gemini mcp list` shows Tavily/Snyk as `Connected`, these messages are Gemini telemetry/implementation warnings rather than an MCP connection failure.

The current package intentionally enables local Gemini telemetry to `/var/log/sandbox/gemini-telemetry.log` for metadata/audit purposes. Do not simply disable telemetry in `.env` or Compose without coordinating the corresponding runtime verification and logging design. A Gemini CLI version upgrade should be handled as a normal controlled application-version change and regression-tested before the client demo.

## 11.27 Direct Gemini is blocked by corporate IT

If Windows/corporate control blocks direct access to the Google Gemini API, this does not necessarily block the approved Databricks route.

Use:

```bash
ucode gemini
```

and verify Databricks + MCP operation there. The same principle applies to direct Claude if its direct provider endpoint is blocked.

## 11.28 `TCP_DENIED/403` in Squid logs

This normally means the default-deny policy is working. For example:

```text
CONNECT mobile.events.data.microsoft.com:443 ... TCP_DENIED/403
```

The `172.x.x.x` address on the left is typically the source DevContainer's Docker-private IP, not an external destination. Do not whitelist a domain merely because a background component tried to reach it. Add only Security-approved destinations needed by an approved capability.

Real-time PowerShell log viewing:

```powershell
Get-Content .\logs\squid\access.log -Tail 50 -Wait
```

or, depending on how the log is exposed:

```powershell
docker logs --tail 50 -f <squid-container-name>
```

## 11.29 Application works manually but not through MCP

Separate the layers:

```text
1. CLI / API connectivity
2. SSM secret retrieval
3. MCP registration
4. MCP stdio startup
5. agent tool invocation
```

For Tavily:

```bash
tvly search "test"
claude mcp list
gemini mcp list
```

Then invoke Tavily explicitly from the AI agent. A successful `tvly search` proves Tavily API/SSM connectivity, not MCP integration.

## 11.30 Workspace files disappear after container restart

The intended project path is the host-mounted `workspace/` folder -> `/home/vscode/workspace`. Put project source there. Files written elsewhere in the read-only/ephemeral runtime may not persist. Named volumes retain supported tool state; temporary ucode HOME and `/tmp` are intentionally ephemeral.

---

# 12. Folder structure — what every major directory is for

```text
package-root/
+-- .build.env.example              Admin build/release input template
+-- .env.example                    Developer runtime configuration template
+-- .dockerignore                   Root Docker build-context exclusion policy
+-- README.md                       Short package entry point
|
+-- .devcontainer/
|   +-- Dockerfile                  Final DevContainer image build
|   +-- cis-level1-harden.sh        Image-level hardening script
|   +-- devcontainer.json           VS Code Dev Container definition
|   +-- post-create.sh              First Dev Container initialization
|   `-- scripts/                    Runtime wrappers, audit, SSM, MCP and verification
|
+-- ado-scripts/                    Azure DevOps PAT/auth/PR/pipeline helpers
+-- docs/                           Optional Admin documentation (SLIM package only)
+-- ecr/                            Production Compose/runtime artifacts
+-- poc/                            POC Compose and generated TAR image area
+-- policies/                       Example Docker/Desktop/Admin policy
+-- scripts/
|   +-- admin/                      Top-level build/export orchestration
|   +-- applications/               Add/remove/validate source-maintenance helpers
|   +-- ci/                         Package lint/static QA
|   +-- common/                     .build.env parser/validator
|   +-- ecr/                        Production deployment/pull/start helpers
|   +-- hardening/                  Hardened-base creation
|   +-- monitoring/                 Host/Sentinel forwarding helpers
|   +-- platform/                   SSM, ECR, logging setup
|   +-- poc/                        POC build/export/load/start/verify
|   +-- security/                   CIS final image assessment
|   `-- supply-chain/               Digest/hash/commit resolvers
|
+-- security/                       CIS tailoring guidance and scanner Dockerfile
+-- sentinel/                       DCR examples and detection KQL
+-- squid/                          Squid image, ACL configuration, allowlist
+-- templates/developer/            Inputs used to generate Developer packages
`-- workspace/                      Host-persistent Developer project folder
```

A complete per-file inventory is included later in this document in the technical-reference appendix.

---

# 13. Application add/remove — required operating model

The package supports two approaches:

1. **Helper-managed source integration** using `scripts/applications/*`.
2. **Manual explicit integration** for built-in/complex applications.

The helper is a **source-code modification tool**, not a runtime package manager. Adding an approved application changes the Admin package source, after which you lint, rebuild, assess, and redistribute a new image.

## 13.1 Always preview first

Example npm CLI:

```powershell
pwsh -NoProfile -File .\scripts\applications\add-application.ps1 `
  -Name acme-ai `
  -Command acme `
  -InstallType npm `
  -Package '@acme/cli' `
  -Version '1.2.3' `
  -SecretEnv ACME_TOKEN `
  -SsmParameter acme-token `
  -Egress '.acme.example' `
  -ConfigDir '/home/vscode/.config/acme'
```

Without `-Apply`, this is preview mode.

After reviewing the diff/plan:

```powershell
pwsh -NoProfile -File .\scripts\applications\add-application.ps1 `
  -Name acme-ai `
  -Command acme `
  -InstallType npm `
  -Package '@acme/cli' `
  -Version '1.2.3' `
  -SecretEnv ACME_TOKEN `
  -SsmParameter acme-token `
  -Egress '.acme.example' `
  -ConfigDir '/home/vscode/.config/acme' `
  -Apply
```

Then validate:

```powershell
pwsh -NoProfile -File .\scripts\applications\validate-application.ps1 `
  -Name acme-ai `
  -RunLint
```

Then rebuild the image. The Developer should never `npm install -g`, `pip install`, or apt-install an unapproved tool into a running production sandbox as a substitute for the Admin application release process.

## 13.2 Adding MCP to a new application

Use `-Mcp` when the app has a reviewed MCP server integration. If the vendor MCP is exposed as a subcommand, also use `-McpSubcommand`.

A secure secret-backed MCP pattern should mirror Tavily/Snyk:

```text
AI agent
 -> Admin-managed MCP definition
 -> SSM-aware MCP wrapper
 -> run-with-ssm-secrets --profile <app>
 -> retrieve only app secret
 -> vendor MCP child process
```

Do not hard-code API keys in `.mcp.json`, Gemini `settings.json`, shell profiles or workspace files.

## 13.3 Remove an application

Preview:

```powershell
pwsh -NoProfile -File .\scripts\applications\remove-application.ps1 -Name acme-ai
```

Apply:

```powershell
pwsh -NoProfile -File .\scripts\applications\remove-application.ps1 -Name acme-ai -Apply
```

Then lint, manually review residual configuration, rebuild and retest. The helper intentionally does not blindly delete shared SSM parameters, shared egress domains, persistent Developer data or external IAM/service configuration that could be shared or need formal retirement.

The full detailed helper/manual runbook is appended later in this guide.

---

# 14. Minimum demo-ready acceptance checklist

Before the client demo, confirm:

- [ ] v1.16.13 image is rebuilt/reloaded after the latest MCP changes.
- [ ] `docker compose ps` shows Squid healthy and DevContainer running.
- [ ] `verify-runtime` passes or only approved/documented warnings remain.
- [ ] Host `verify-sandbox.ps1 -Path poc` passes the required controls.
- [ ] AWS bootstrap authentication works without displaying credentials.
- [ ] `/sandbox/databricks-token` exists.
- [ ] `/sandbox/tavily-api-key` exists.
- [ ] `/sandbox/snyk-token` exists if Snyk will be demoed.
- [ ] Databricks host is correct and allowlisted.
- [ ] `DATABRICKS_CLAUDE_MODEL` and/or `DATABRICKS_GEMINI_MODEL` are configured.
- [ ] `claude mcp list` shows Tavily/Snyk connected if direct route is tested.
- [ ] `gemini mcp list` shows Tavily/Snyk connected if direct route is tested.
- [ ] `ucode claude` starts through Databricks and `/mcp` can see Tavily/Snyk.
- [ ] `ucode gemini` starts through Databricks and `/mcp list` can see Tavily/Snyk.
- [ ] Tavily MCP performs one approved search successfully.
- [ ] Snyk MCP performs one scan successfully if included in demo.
- [ ] Squid log can be tailed live from PowerShell.
- [ ] An unapproved egress request shows `TCP_DENIED/403`.
- [ ] No secrets are printed in terminal screenshots/demo logs.

---

# 15. Exact/pinned DevContainer application versions in v1.16.13

The table below distinguishes **source-pinned versions** from components whose exact runtime version is determined by the digest or installer at image-build time.

| Component | Version/source in v1.16.13 | Pinning status | Notes |
|---|---|---|---|
| Ubuntu runtime base | `ubuntu:24.04` + resolved immutable SHA-256 digest | Digest-pinned before build | Final `BASE_IMAGE` becomes the hardened base digest |
| Node source image | `node:20-bookworm-slim` + resolved digest | Digest-pinned | Exact Node/npm patch comes from resolved image digest |
| Claude Code | `2.1.212` | Exact version | npm global install |
| Gemini CLI | `0.53.0` | Exact version | npm global install |
| Tavily CLI | `0.1.6` | Exact version | installed with `uv tool` |
| Tavily MCP | `0.2.21` | Exact version | npm global install |
| Snyk CLI package | `1.1306.2` | Exact version | npm global install; Snyk may use its own runtime cache internally |
| Databricks CLI | `1.10.0` | Exact version + SHA-256 | ZIP release |
| Databricks ucode | immutable 40-hex `UCODE_GIT_REF` resolved from `main` | Commit-pinned per release build | Source template does not contain a final commit until resolver runs |
| Git Credential Manager | `2.5.0` | Exact version; hash resolver supported | `.deb` install |
| ComplianceAsCode / SSG | `0.1.80` | Exact version + SHA-256 | Build/assessment content, not a Developer CLI |
| AWS CLI | AWS CLI v2 Linux ZIP at `AWSCLI_URL` | Artifact hash resolved; semantic version not fixed in template | Exact installed version must be captured from built image |
| Azure CLI | Microsoft `InstallAzureCLIDeb` result | Not semantic-version pinned in current Dockerfile | Exact installed version is build-date dependent |
| `uv` | Astral install script result | Not semantic-version pinned in current Dockerfile | Capture from built image |
| Python | Ubuntu 24.04 repository `python3` | Repository/digest determined | Exact patch depends on hardened base build state |
| Git / Git LFS / jq / curl / OpenSSH client / vim-tiny | Ubuntu repository packages | Repository/digest determined | Capture exact package versions from final image when release evidence is required |
| npm | Bundled with digest-pinned Node source image | Image-digest determined | Capture from built image |

## 15.1 Capture exact versions from a built DevContainer

Run inside the final DevContainer and retain the output as release evidence if required:

```bash
cat /etc/os-release
node --version
npm --version
python3 --version
git --version
git-lfs --version
jq --version
aws --version
az version
databricks --version
claude --version
gemini --version
snyk --version
uv --version
git-credential-manager --version 2>/dev/null || true
/usr/local/libexec/ai-sandbox/real/ucode --version 2>/dev/null || true
npm list -g --depth=0 2>/dev/null | grep -E 'claude-code|gemini-cli|tavily-mcp|snyk'
uv tool list
cat /etc/ai-sandbox/build-info.json
```

For the immutable ucode source revision, the authoritative release value is also recorded in the generated image manifest/build provenance after `.build.env` has been resolved.

---

# 16. Detailed technical reference from the v1.16.13 package

The following reference is consolidated from the package's Admin documentation and has been updated here with the v1.16.13 Databricks-routed MCP temporary-HOME behavior.

# AI Secure Sandbox v1.16.13 — Complete Package, Build, Runtime and Maintenance Guide

> **Document status:** This is the authoritative detailed operational guide for the v1.16.13 Admin package. The active build package intentionally excludes release-history, package-cleanup, language-audit, and QA-evidence files. Those records belong in source control, release storage, change management, or an external evidence repository when required. The `docs/` directory is documentation-only and is not a build, export, deploy, or lint dependency.

## 1. What this package is

AI Secure Sandbox v1.16.13 is an Admin-built, two-container development environment for Windows 365 and Docker Desktop. The Admin validates and pins external build inputs, creates a hardened Ubuntu 24.04 base, builds the DevContainer and Squid proxy, assesses the final DevContainer with OpenSCAP, and then distributes either POC TAR images or Production ECR digests.

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
AI_Sandbox_Admin_v1_16_13_...
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

v1.16.13 adds an explicit hardened-base reuse mode for repeated POC or Production image builds where the OS hardening baseline has not changed. This is useful when testing DevContainer scripts, application wrappers, Dockerfile application layers, Squid configuration, logging, or other changes above the hardened OS layer.

The safest workflow is to copy the previously resolved `.build.env` from the last successful build into the new v1.16.13 Admin package and then request reuse:

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

When a previous `.build.env` is copied, the Admin entry point updates `SANDBOX_VERSION` to `v1.16.13`. If `RELEASE_TAG` still equals the previous package version, it is updated to `v1.16.13` as well; an intentionally custom release tag is preserved.

For Production, a valid reused Production hardened base does not require the Ubuntu Pro token again. If reuse validation fails and a new Production hardened base is required, the Ubuntu Pro token becomes mandatory as in the normal build path.

Without `-ReuseHardenedBase`, behavior is unchanged: the hardened base is rebuilt.

## 6. POC build call graph

The POC path is:

```text
scripts/admin/build-sandbox.ps1 -SandboxType POC
  |
  |-- [0] Ensure .build.env exists and stamp v1.16.13
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

The POC Developer package must contain v1.16.13 images. Do not reuse older v1.16.3 TAR images because this v1.16.13 baseline adds dual-mode AWS authentication helpers (static-key priority with browser SSO fallback) and `sandbox-info` inside the DevContainer image.

## 7. Production build call graph

The Production path begins with the same supply-chain resolution steps and then switches to Ubuntu Pro/USG hardening and ECR publication:

```text
scripts/admin/build-sandbox.ps1 -SandboxType Production
  |
  |-- ensure .build.env exists and stamp v1.16.13
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

v1.16.13 includes read-only, non-secret build provenance under:

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
[3/5] Configure secret-free MCP definitions
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
| Tavily | `/sandbox/tavily-api-key` | SecureString | `TAVILY_API_KEY` |
| Snyk | `/sandbox/snyk-token` | SecureString | `SNYK_TOKEN` |
| HiddenLayer | `/sandbox/hiddenlayer-client-id` | SecureString | `HIDDENLAYER_CLIENT_ID` |
| HiddenLayer | `/sandbox/hiddenlayer-client-secret` | SecureString | `HIDDENLAYER_CLIENT_SECRET` |
| ADO | `/sandbox/ado-org` | String | `ADO_ORG` |
| ADO | `/sandbox/ado-project` | String | `ADO_PROJECT` |
| ADO | `/sandbox/ado-repo` | String | `ADO_REPO` |
| ADO | `/sandbox/ado-pat` | SecureString | `ADO_PAT` |

v1.16.13 intentionally treats the SSM-backed ADO path as PAT-based. The previous partially implemented Service Principal parameter branch was removed to avoid presenting an incomplete authentication path as supported.

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

### v1.16.13 Databricks-routed MCP propagation

`ucode claude` and `ucode gemini` run with a short-lived HOME created under `/tmp/ai-sandbox-ucode.*`. User-scope MCP definitions from `/home/vscode/.claude` or `/home/vscode/.gemini` are therefore not automatically visible to the Databricks-routed agent. v1.16.13 addresses this by running `/usr/local/bin/configure-mcp` again inside the temporary ucode HOME after successful headless `ucode configure`.

The temporary agent HOME therefore receives only the Admin-managed Tavily and Snyk MCP definitions. Tavily/Snyk credentials are still not copied into the temporary HOME. Each MCP wrapper retrieves its own SSM secret only when the MCP process starts. For Gemini, the MCP definition includes environment-variable references such as `$AWS_ACCESS_KEY_ID` rather than credential values so Gemini's MCP environment sanitization does not remove the AWS bootstrap variables needed by the SSM-aware wrapper.

```text
ucode claude / ucode gemini
  -> SSM databricks-token
  -> temporary HOME
  -> headless ucode configure
  -> configure-mcp inside temporary HOME
       -> tavily-mcp-ssm
       -> snyk-mcp-ssm
  -> Databricks-routed Claude/Gemini agent
       -> MCP tool start
       -> SSM Tavily/Snyk credential retrieval
       -> approved tool API
  -> temporary HOME deleted on agent exit
```

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

The SSM-backed ADO runtime path in v1.16.13 is PAT-based. If Azure CLI bearer-token mode is used by a separate helper, it depends on an already approved Azure CLI authentication context and should not be confused with the removed incomplete SSM Service Principal branch.

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

v1.16.13 provides Admin-only helpers:

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

## v1.16.13 optional AI content logging

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


## v1.16.13 runtime compatibility update

- Snyk now uses `/run/ai-sandbox-snyk`, a dedicated ephemeral `exec,nosuid,nodev` tmpfs, because the Snyk CLI downloads and executes a versioned native runtime from its cache. `/tmp` and `/var/tmp` remain `noexec`.
- When `-ReuseHardenedBase`/`--reuse-hardened-base` is used, the build refreshes only the immutable `UCODE_GIT_REF` from Databricks ucode `main`; the hardened Ubuntu base is still reused.
- The DevContainer Dockerfile fails the Admin build unless the pinned ucode commit supports `--profiles`, `--use-pat`, `--skip-validate`, and `--skip-upgrade`, preventing the old interactive-browser-login regression from reaching Developers.


---

# 17. Full Admin application add/remove runbook

The following is the detailed helper and manual application-maintenance runbook included with the SLIM package.

# AI Secure Sandbox v1.16.13 - Admin Application Add / Remove Runbook

## 1. Purpose

v1.16.13 preserves the v1.16.3 explicit runtime architecture but makes Admin application onboarding/removal less repetitive. It does **not** introduce a runtime application catalog and it does **not** install applications dynamically when a Developer starts the container.

The helper edits the same source files an Admin would edit manually in v1.16.13, and generated source is still visible for security review.

## 2. What v1.16.13 adds

```text
scripts/applications/
├── add-application.ps1
├── add-application.sh
├── remove-application.ps1
├── remove-application.sh
├── validate-application.ps1
├── validate-application.sh
├── application-helper.py
└── records/
```

On Windows, the PowerShell launchers require PowerShell 7.4+ (`pwsh`). The PowerShell and shell launchers call the same Admin-side Python 3 source editor so Windows/Linux output is consistent. Python is required only on the Admin source/build workstation for these helpers; it is not a new runtime dependency inside the Developer package.

If Python 3 is not approved/available on the Admin workstation, use the manual procedure in Section 22 of this runbook instead.

## 3. Security model remains unchanged

After Apply, the source still contains explicit code such as:

```text
Dockerfile install
    -> real/<command> stash
    -> sandbox-command-wrapper
    -> run-with-ssm-secrets profile
    -> AWS SSM
    -> real executable
    -> Squid approved service
```

The helper only reduces repetitive Admin editing.

## 4. Generated source markers

Every block generated for an application is marked:

```text
# BEGIN AI-SANDBOX APP acme-ai
...
# END AI-SANDBOX APP acme-ai
```

`remove-application` removes only blocks with that exact application marker. Existing v1.16.13 built-in application code is intentionally not converted into these markers.

The helper also creates:

```text
scripts/applications/records/<name>.json
```

This record is Admin source metadata for validation/removal. It is not copied into the DevContainer and is not read at runtime.

## 5. Supported install templates

| `InstallType` | Use | Required input |
|---|---|---|
| `npm` | Node CLI | package + exact version |
| `uv` | Python CLI | package + exact version |
| `apt` | package already available in configured apt repositories | package + exact apt version |
| `archive` | binary / ZIP / TAR.GZ download | HTTPS URL + SHA-256 + format; binary path for ZIP/TAR |
| `custom` | exceptional vendor install flow | locally reviewed Dockerfile snippet |

The helper deliberately does not provide a parameter for an arbitrary remote `curl | sh` installer.

For AWS CLI-like installation flows where a ZIP contains an installer program rather than only a binary, use a reviewed `custom` snippet or the v1.16.13 manual process.

## 6. Preview is mandatory operational practice

The helper defaults to preview. It modifies files only when `-Apply` / `--apply` is supplied.

Recommended sequence:

```text
Preview
  -> review planned files and parameters
Apply
  -> review git diff
Validate
  -> package lint
POC build/test
  -> Production release
```

## 7. Add an npm CLI - PowerShell

Preview:

```powershell
.\scripts\applications\add-application.ps1 `
  -Name acme-ai `
  -Command acme `
  -InstallType npm `
  -Package '@acme/cli' `
  -Version '1.2.3' `
  -SecretEnv ACME_API_TOKEN `
  -SsmParameter acme-api-token `
  -Egress '.acme.example' `
  -ConfigDir '.config/acme'
```

Apply after review:

```powershell
.\scripts\applications\add-application.ps1 `
  -Name acme-ai `
  -Command acme `
  -InstallType npm `
  -Package '@acme/cli' `
  -Version '1.2.3' `
  -SecretEnv ACME_API_TOKEN `
  -SsmParameter acme-api-token `
  -Egress '.acme.example' `
  -ConfigDir '.config/acme' `
  -Apply
```

Only the **secret environment-variable name** and **SSM parameter name** are command-line inputs. Never pass the real token/API key to the application helper.

## 8. Equivalent shell example

```bash
./scripts/applications/add-application.sh \
  --name acme-ai \
  --command acme \
  --install-type npm \
  --package '@acme/cli' \
  --version '1.2.3' \
  --secret-env ACME_API_TOKEN \
  --ssm-parameter acme-api-token \
  --egress '.acme.example' \
  --config-dir '.config/acme'
```

Add `--apply` after reviewing preview output.

## 9. What Apply changes for a secret-backed CLI

The helper normally creates marked blocks in:

```text
.devcontainer/Dockerfile
.devcontainer/scripts/sandbox-command-wrapper.sh
.devcontainer/scripts/run-with-ssm-secrets.sh
.devcontainer/scripts/application-audit.sh
.devcontainer/scripts/verify-runtime.sh
scripts/platform/01-setup-ssm.sh
scripts/platform/01-setup-ssm.ps1
squid/whitelist.txt                 # if egress supplied
```

It also creates the Admin record JSON.

### Dockerfile

The generated blocks contain:

- pinned install;
- real executable stash;
- optional narrow writable config directory;
- Developer-facing public symlink to the Admin command wrapper;
- optional MCP helper COPY/chmod.

### Public command wrapper

The Developer uses the normal command. The generated branch resolves the real executable, permits safe local help/version operations, and sends secret-backed operations to the app's SSM profile.

### SSM runner

The helper adds:

- profile name allowlisting;
- `get_parameter <ssm-name>`;
- process-scoped `export <ENV>`;
- sanitized credential-fetch/process audit metadata;
- `run_logged` execution.

### SSM setup

The same parameter name is inserted into both Admin SSM setup scripts. The actual value is entered securely when the setup script is executed.

### Squid

Supplied `--egress` values are inserted into the allowlist as marked entries. After Apply, package lint must be used to detect domain overlaps.

## 10. uv/Python example

```powershell
.\scripts\applications\add-application.ps1 `
  -Name pytool `
  -Command pytool `
  -InstallType uv `
  -Package 'pytool' `
  -Version '4.1.0' `
  -SecretEnv PYTOOL_TOKEN `
  -SsmParameter pytool-token `
  -Egress '.pytool.example' `
  -Apply
```

The exact version is written into explicit Dockerfile source for the helper-managed app. Existing built-in v1.16.13 tools keep their original build-ARG approach.

## 11. Archive examples

### Direct binary

```powershell
.\scripts\applications\add-application.ps1 `
  -Name vendcli `
  -Command vendcli `
  -InstallType archive `
  -Url 'https://downloads.vendor.example/vendcli-2.0.0-linux-amd64' `
  -Sha256 '<APPROVED_64_HEX_SHA256>' `
  -ArchiveFormat binary `
  -SecretEnv VENDCLI_TOKEN `
  -SsmParameter vendcli-token `
  -Egress '.vendor.example' `
  -Apply
```

The generated Dockerfile downloads over HTTPS, verifies SHA-256, then installs the executable.

### ZIP

Add:

```text
-ArchiveFormat zip
-BinaryPath 'vendcli/bin/vendcli'
```

### TAR.GZ

Use:

```text
-ArchiveFormat tar.gz
-BinaryPath 'vendcli/bin/vendcli'
```

`BinaryPath` must be a safe relative extraction path.

## 12. apt example

Use `apt` only when the approved repository is already configured in the image build and an exact version is known.

```powershell
.\scripts\applications\add-application.ps1 `
  -Name sample `
  -Command sample `
  -InstallType apt `
  -Package 'sample-cli' `
  -Version '2.4.1-1' `
  -Apply
```

If a new vendor apt repository, signing key, or repository bootstrap is required, use a reviewed custom snippet or the manual runbook. Do not hide repository trust configuration inside the helper.

## 13. custom install example

Create a local reviewed file, for example:

```text
admin-snippets/acme-install.dockerfile
```

The file should contain only the Dockerfile commands required to install the approved pinned app. Then:

```powershell
.\scripts\applications\add-application.ps1 `
  -Name acme-ai `
  -Command acme `
  -InstallType custom `
  -CustomSnippet '.\admin-snippets\acme-install.dockerfile' `
  -SecretEnv ACME_API_TOKEN `
  -SsmParameter acme-api-token `
  -Egress '.acme.example' `
  -Apply
```

`custom` means the helper performs source insertion only. It does not determine whether the supplied installer is safe. Review HTTPS, version pinning, signature/checksum, repository keys, installed paths, and cleanup manually.

## 14. Add an MCP integration

For a simple MCP server launched as the application's binary plus an optional subcommand:

```powershell
.\scripts\applications\add-application.ps1 `
  -Name acme-ai `
  -Command acme `
  -InstallType npm `
  -Package '@acme/cli' `
  -Version '1.2.3' `
  -SecretEnv ACME_API_TOKEN `
  -SsmParameter acme-api-token `
  -Egress '.acme.example' `
  -Mcp `
  -McpSubcommand mcp `
  -Apply
```

The helper creates:

```text
.devcontainer/scripts/acme-ai-mcp-ssm.sh
```

and adds secret-free Claude/Gemini user-scope MCP registration pointing to:

```text
/usr/local/bin/acme-ai-mcp-ssm
```

The MCP wrapper records only lifecycle metadata (`server_start`, `server_end`, exit/duration, `stdio`). It does not log MCP request/response bodies.

If the MCP server requires complex arguments, transport flags, multiple binaries, or special environment setup, treat the generated wrapper as a starting point and manually review/edit it before release.

## 15. Validate after Apply

PowerShell:

```powershell
.\scripts\applications\validate-application.ps1 -Name acme-ai -RunLint
```

Shell:

```bash
./scripts/applications/validate-application.sh --name acme-ai --run-lint
```

Validation checks that helper-managed markers exist in the expected integration files, MCP wrapper exists when requested, markers are balanced, and optionally runs the existing package lint.

Validation is not a substitute for `git diff`. Always inspect the generated source.

## 16. Configure the actual SSM credential

After source validation, execute the normal Admin SSM setup workflow for the target environment. Enter the credential only at the secure prompt generated in `01-setup-ssm`.

Confirm:

```text
helper SsmParameter == setup script parameter == run-with-ssm-secrets get_parameter name
```

Do not put the credential in the helper record JSON.

## 17. POC acceptance after adding an app

1. Package lint passes.
2. Review source diff.
3. Build POC DevContainer/Squid images. For application-layer-only changes, v1.16.13 may use `build-sandbox.ps1 -SandboxType POC -ReuseHardenedBase`; the Admin entry point reuses the old hardened base only after validating the complete copied `.build.env`, the exact digest, and hardening labels, and automatically rebuilds the hardened base if any requirement fails.
4. Start the POC Sandbox.
5. Confirm `/usr/local/bin/<command>` resolves to the Admin wrapper.
6. Confirm `/usr/local/libexec/ai-sandbox/real/<command>` exists.
7. Confirm AWS authentication: static Access Key/Secret Key is used first when present; browser SSO is the fallback when static keys are absent.
8. Run local help/version without unnecessary secret fetch where supported.
9. Run one approved real operation.
10. Confirm app event log creation for secret-backed apps.
11. Confirm Squid access logging and destination behavior.
12. If MCP enabled, test from both Claude and Gemini.
13. Verify `mcp-events.log` and `<app>-events.log` correlation.
14. Search logs for a dummy secret and a deliberately confidential test argument/query; neither should be present in application/MCP audit logs.
15. Run image/CIS/security acceptance gates.

## 18. Production release

An app add/remove still requires a new DevContainer image. v1.16.13 does not make runtime installation dynamic.

For Production:

1. complete POC/security acceptance;
2. build the Production image;
3. publish immutable ECR digest;
4. if Squid changed, publish new Squid digest;
5. publish/update the approved-image manifest;
6. verify Developer `pull-and-start` resolves the newly approved image;
7. retain previous approved digest according to rollback policy.

## 19. Remove a helper-managed v1.16.13 app

### Preview removal

PowerShell:

```powershell
.\scripts\applications\remove-application.ps1 -Name acme-ai
```

Shell:

```bash
./scripts/applications/remove-application.sh --name acme-ai
```

The preview lists every source file that contains that application's generated marker.

Before Apply, determine whether any generated Squid domain or SSM parameter is shared with another workload.

### Apply removal

```powershell
.\scripts\applications\remove-application.ps1 -Name acme-ai -Apply
```

or:

```bash
./scripts/applications/remove-application.sh --name acme-ai --apply
```

The helper removes only exact `BEGIN/END AI-SANDBOX APP acme-ai` blocks, deletes the generated MCP launcher if one exists, and deletes the helper record.

## 20. What remove-application intentionally does not delete

The helper does **not**:

- call AWS SSM delete-parameter;
- revoke a vendor API key;
- delete a SaaS account;
- determine whether a Squid domain is shared outside helper-managed source;
- delete an old ECR image/digest;
- change the central approved manifest automatically.

Those actions have wider impact and require explicit Admin/change review.

Preferred credential-removal order:

```text
remove app from source/image
-> validate + POC
-> publish removal image
-> confirm old image retirement
-> revoke vendor credential
-> delete/disable SSM parameter
```

## 21. Removing built-in v1.16.13 applications

Claude, Gemini, Tavily, Snyk, Databricks, and any application integrated manually before v1.16.13 do not have helper records/markers.

Do not attempt to fabricate a record and run `remove-application` against them. Use:

```text
docs/ADMIN-APPLICATION-ADD-REMOVE.md
```

and reverse each explicit integration point manually.

## 22. Failure and rollback

If Apply produces an unexpected source change:

1. stop before image publication;
2. inspect `git diff`;
3. use `remove-application` for a correctly recorded helper-managed addition, or revert source control;
4. rerun package lint;
5. do not publish the image until the complete POC/security acceptance passes.

Production rollback is by approved immutable image digest/manifest, not only by source rollback.

## 23. Admin add checklist

- [ ] approval/change ticket exists
- [ ] preview reviewed
- [ ] install source is approved
- [ ] exact version is pinned
- [ ] direct download has approved SHA-256
- [ ] no unreviewed pipe-to-shell installer introduced
- [ ] only secret *names*, not secret values, supplied to helper
- [ ] generated Dockerfile block reviewed
- [ ] wrapper/SSM branch reviewed
- [ ] SSM setup names match
- [ ] audit metadata contains no content/secrets
- [ ] Squid domains are minimum required and non-overlapping
- [ ] MCP registration is secret-free
- [ ] validator passed
- [ ] package lint passed
- [ ] source diff reviewed
- [ ] POC functional test passed
- [ ] negative secret/query audit test passed
- [ ] CIS/security gates passed
- [ ] Production immutable digest/manifest updated

## 24. Admin removal checklist

- [ ] removal approved
- [ ] removal preview reviewed
- [ ] shared domains checked
- [ ] shared SSM parameters checked
- [ ] Apply removed only expected marker blocks
- [ ] validator/package lint passed after removal
- [ ] POC confirms command/MCP is absent
- [ ] Squid still works for remaining apps
- [ ] Production removal image/digest published
- [ ] old image retirement confirmed
- [ ] vendor credential revoked after retirement
- [ ] SSM parameter deleted/disabled after retirement
- [ ] documentation/change evidence updated

## 25. Manual explicit add procedure (built-in / exceptional applications)

Use this section when the application is a built-in integration, when Python helpers are unavailable, or when the install/authentication flow is too unusual for the helper templates. This preserves the explicit v1.16.3-style source model.

### 25.1 Collect approval inputs before editing

Record all of the following before changing source:

1. application name, business owner, change/security approval;
2. Developer-facing command(s);
3. official vendor installation method;
4. exact approved version (never `latest` or an open range);
5. for direct downloads, the exact HTTPS source URL and approved SHA-256;
6. runtime secret environment-variable names;
7. exact SSM parameter names under the approved Sandbox prefix;
8. required outbound FQDN/domain list;
9. MCP launch command/transport if applicable;
10. required narrow writable config/cache directories;
11. safe audit operation names and target identifiers;
12. rollback/removal dependencies, including shared domains and credentials.

### 25.2 Add build-time inputs

For version/source/hash values that must be controlled by Admin build configuration:

- add non-secret values to `.build.env.example`;
- add required-variable/format validation to `scripts/common/Load-BuildEnv.ps1` and `scripts/common/load-build-env.sh` when appropriate;
- propagate new Docker build arguments through both `scripts/poc/build-and-export.*` and `scripts/platform/02-setup-ecr.*`;
- declare/redeclare the matching `ARG` in the required Dockerfile stage(s).

Do **not** place runtime tokens/API keys/PATs in `.build.env`.

### 25.3 Install the application in `.devcontainer/Dockerfile`

Install during image build, not in `post-create.sh`. Preferred patterns are:

- npm: exact `package@version`;
- uv/Python: exact version or immutable Git commit;
- direct binary/archive: HTTPS source + SHA-256 validation before install;
- apt/deb: approved repository/package version according to supply-chain policy.

Avoid unverified remote `curl | sh`. If a vendor bootstrap installer is unavoidable, mirror/review/pin it according to the organisation's software supply-chain process.

### 25.4 Verify and stash the real executable

Before creating a public wrapper, verify that the expected executable exists and, where safe, that `--version`/`--help` works. Preserve the real vendor executable under:

```text
/usr/local/libexec/ai-sandbox/real/<command>
```

This prevents wrapper recursion and allows Admin-controlled public command paths.

### 25.5 Add only required writable directories

The runtime root filesystem is read-only. If the application needs local state, add only a narrowly scoped directory under `/home/vscode` and map/provision only that path. Do not make broad system locations writable as a workaround.

### 25.6 Add the public wrapper branch

Edit `.devcontainer/scripts/sandbox-command-wrapper.sh`.

- local inspection operations such as `--version`/`--help` may call the real binary without SSM when safe;
- secret-backed runtime operations must call `run-with-ssm-secrets --profile <app> -- <real-binary> ...`;
- never log or copy raw `$@` into audit files.

### 25.7 Add the SSM profile and runtime secret mapping

For a secret-backed app, edit `.devcontainer/scripts/run-with-ssm-secrets.sh`:

1. add the profile name to the allowlist;
2. add a profile branch;
3. call `get_parameter` only for the minimum required SSM names;
4. export the credential only for the child process;
5. emit sanitized `credential_fetch` metadata;
6. use `run_logged` with safe operation/target identifiers;
7. do not persist fetched values into workspace, `.env`, shell profiles, MCP settings, or image layers.

### 25.8 Add Admin SSM bootstrap

Update both:

```text
scripts/platform/01-setup-ssm.sh
scripts/platform/01-setup-ssm.ps1
```

Use `SecureString` for credentials. The SSM name must exactly match the runtime `get_parameter` name. Source files may contain parameter names but never real secret values.

### 25.9 Add application audit support

If `run-with-ssm-secrets` emits `application-audit --app <app>`, add the app identifier to `.devcontainer/scripts/application-audit.sh`.

Audit only sanitized metadata. Do not log prompts, queries, request/response bodies, source code, findings, credentials, remote URLs containing credentials, or complete command arguments.

Expected host log for a normal app is:

```text
C:\ProgramData\AI-Sandbox\Logs\devcontainer\<app>-events.log
```

### 25.10 Add Squid egress only when required

Edit `squid/whitelist.txt` with the minimum approved destinations. Do not add both a parent suffix such as `.example.com` and a child/apex already covered by that suffix; package lint rejects overlaps.

Any Squid allowlist change requires a new Squid image/release as well as a DevContainer release when the application set changed.

### 25.11 Add MCP when applicable

For an MCP integration:

1. create `.devcontainer/scripts/<app>-mcp-ssm.sh`;
2. resolve the real binary under `/usr/local/libexec/ai-sandbox/real/`;
3. record only MCP lifecycle metadata;
4. invoke the MCP child through `run-with-ssm-secrets` when a secret is needed;
5. COPY/chmod the wrapper in the Dockerfile;
6. register it secret-free for Claude/Gemini in `configure-mcp.sh`;
7. never place API keys/tokens in MCP configuration;
8. extend runtime verification for the wrapper and registration.

### 25.12 Extend runtime verification and package lint

At minimum verify:

- public command exists;
- public command resolves to the Admin wrapper when intended;
- real executable exists;
- runtime secret is absent from the parent environment;
- required writable path works;
- MCP wrapper/registration exists when applicable.

Add package-lint assertions for any new security invariant that must never silently regress.

### 25.13 Acceptance/release sequence

```text
source change
 -> Bash + PowerShell lint
 -> POC image build
 -> POC start
 -> browser SSO login
 -> local help/version test
 -> real approved operation
 -> application/MCP/Squid audit correlation
 -> dummy-secret/content non-leakage test
 -> CIS/image/security gates
 -> Production immutable ECR digest
 -> approved manifest update
```

An application addition always changes the DevContainer image. A Squid allowlist change also changes the Squid image.

## 26. Manual explicit removal procedure

Do not remove only the install line. First identify whether any other application shares the executable, package, SSM parameter, vendor credential, Squid domain, writable directory, MCP registration, or audit expectation.

Reverse every applicable integration point:

1. remove Dockerfile install code;
2. remove obsolete build `ARG` declarations/redeclarations;
3. remove unused `.build.env.example` values;
4. remove build-env required-variable/validation entries;
5. remove POC/Production build-argument propagation;
6. remove the `real/<command>` stash step;
7. remove the public symlink/wrapper branch;
8. remove the SSM profile allowlist/branch;
9. remove SSM bootstrap prompts from both SH and PS1;
10. remove application-audit allowlisting only if unused;
11. remove MCP wrapper/COPY/configuration when applicable;
12. remove application-only writable directories/mounts;
13. remove Squid domains only after checking they are not shared;
14. remove runtime verification/lint assertions that are no longer relevant;
15. update the current operational documentation and any external change/release evidence required by your governance process;
16. lint, rebuild and retest POC/Production.

Do **not** delete the SSM parameter or revoke the vendor credential first. Preferred order:

```text
remove app from new source/image
 -> lint + POC acceptance
 -> publish new approved image/digest
 -> verify old image/session retirement
 -> revoke vendor credential
 -> delete/disable SSM parameter
```

This keeps rollback controlled and prevents still-running approved old images from breaking unexpectedly.

## Content-logging integration rule

Do not add request/response bodies to `application-audit.sh` or `<app>-events.log`. If a future AI application requires approved content capture, implement it as a separate `*-content.log` path gated by `SANDBOX_CONTENT_LOGGING=true`, keep the default disabled, use restrictive file permissions, document the exact capture semantics, and add a lint regression that proves metadata logging remains content-free when the flag is disabled.


## v1.16.13 runtime compatibility update

- Snyk now uses `/run/ai-sandbox-snyk`, a dedicated ephemeral `exec,nosuid,nodev` tmpfs, because the Snyk CLI downloads and executes a versioned native runtime from its cache. `/tmp` and `/var/tmp` remain `noexec`.
- When `-ReuseHardenedBase`/`--reuse-hardened-base` is used, the build refreshes only the immutable `UCODE_GIT_REF` from Databricks ucode `main`; the hardened Ubuntu base is still reused.
- The DevContainer Dockerfile fails the Admin build unless the pinned ucode commit supports `--profiles`, `--use-pat`, `--skip-validate`, and `--skip-upgrade`, preventing the old interactive-browser-login regression from reaching Developers.
