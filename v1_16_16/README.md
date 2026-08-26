# AI Secure Sandbox v1.16.16

Admin-built AI development sandbox for Windows 365 + Docker Desktop.

v1.16.16 preserves the v1.16.3 SSM/runtime security model and supports AWS authentication in this order: runtime Access Key/Secret Key pair first, then browser-based IAM Identity Center (SSO) fallback. Admin-only application maintenance helpers are retained.

## v1.16.16 runtime state fixes

- `claude` uses the Anthropic direct SSM key; `gemini` uses the Google Gemini direct SSM key.
- `ucode claude` and `ucode gemini` use the Databricks SSM PAT with headless temporary configuration.
- Tavily/Snyk/Databricks SQL MCP registrations are secret-free; AWS authentication is resolved at MCP launch time (static key pair first, IAM Identity Center SSO otherwise).
- Databricks managed SQL MCP is registered as `databricks-sql`; its PAT is fetched only at MCP start from `<SSM_PREFIX>/databricks-sql-mcp-token`.
- Tavily MCP is fronted by a root-owned allowlist proxy; Claude native WebSearch/WebFetch and Gemini native web tools are disabled by Admin policy.
- `tvly` uses an ephemeral writable HOME so `~/.tavily/config.json` is never required under the read-only user home.
- `snyk` uses ephemeral HOME/XDG cache/config storage so Snyk cache lock files do not require a writable `/home/vscode/.cache`.
- Required non-secret Databricks routing values are `DATABRICKS_HOST`, `DATABRICKS_CLAUDE_MODEL`, and `DATABRICKS_GEMINI_MODEL`.


## Package boundary

The active package is intentionally split into three groups:

- **Build/runtime source**: `.devcontainer/`, `scripts/`, `poc/`, `ecr/`, `squid/`, `security/`, `sentinel/`, `ado-scripts/`, `policies/`, and the root configuration templates.
- **Developer package templates**: `templates/developer/`. These files are real inputs to Developer package export and are therefore validated by package lint.
- **Optional Admin documentation**: `docs/`. These Markdown files are not build inputs, are not runtime inputs, and are not required by package lint. They may be stored separately after review without breaking image build or Developer package export.

Release-history, package-cleanup, language-audit, and QA-evidence documents are intentionally not carried in this active build package. Store those in source control, release storage, change-management systems, or an external evidence repository when required.

## Windows Admin shell requirement

All PowerShell entry points in this package require **PowerShell 7.4 or later** (`pwsh`). Windows PowerShell 5.1 is not a supported execution host for this baseline.

The Developer project folder remains `workspace/` in the Windows package, but Compose mounts it inside the DevContainer at:

```text
/home/vscode/workspace
```

This keeps project files under the non-root `vscode` user's home while preserving the existing host package layout.

## Architecture

```text
Windows 365 Host
  |
  +-- Docker Desktop
  |     +-- DevContainer  -- internal Docker network only
  |     `-- Squid Proxy   -- internal + external networks
  |
  +-- AWS auth: Access Key/Secret Key OR Windows-browser IAM Identity Center SSO/MFA
  |
  `-- Host log directory -> AMA/DCR or Logs Ingestion API -> Sentinel
```

Approved Developer commands include:

```bash
claude                 # Anthropic official API (SSM: claude-api-key)
gemini                 # Google Gemini official API (SSM: gemini-api-key)
ucode claude           # Databricks AI Gateway (SSM: databricks-token)
ucode gemini           # Databricks AI Gateway (SSM: databricks-token)
snyk test
databricks current-user me
```

The command name is the routing boundary: bare `claude` and `gemini` are direct-provider commands; only the explicit `ucode ...` form routes those coding agents through Databricks. Tavily is MCP-first for Claude/Gemini; direct `tvly` remains available for approved troubleshooting.

## Optional Admin documentation

- `docs/ADMIN-COMPLETE-GUIDE.md` — complete architecture, Admin image-build order, file call graph, runtime sequence, SSO, SSM, Squid, logging, and troubleshooting.
- `docs/ADMIN-APPLICATION-ADD-REMOVE.md` — application add/remove Preview/Apply helper and manual fallback process.
- `docs/SECURITY-LOGGING-AND-SENTINEL.md` — runtime security boundary, application audit/log content policy, and Sentinel forwarding.

These documents are useful for operation and review but are deliberately not required by build, export, deploy, or lint workflows.

## Developer package template inputs

```text
templates/developer/
├── env.example
├── devcontainer-production.json
├── DEVELOPER-GUIDE-POC.md
└── DEVELOPER-GUIDE-PRODUCTION.md
```

`scripts/admin/export-developer-packages.*` consumes these files to create the POC and Production Developer packages.

## Admin build entry

POC:

```powershell
Copy-Item .build.env.example .build.env
# Fill/resolve build values and optional Admin-approved Developer SSO fallback defaults.
.\scripts\ci\lint-package.ps1
.\scripts\admin\build-sandbox.ps1 -SandboxType POC
.\scripts\admin\export-developer-packages.ps1 -IncludePocImages
```

Production:

```powershell
Copy-Item .build.env.example .build.env
# Configure ECR/Ubuntu Pro/Admin AWS identity as required by the environment.
.\scripts\ci\lint-package.ps1
.\scripts\admin\build-sandbox.ps1 -SandboxType Production
.\scripts\admin\export-developer-packages.ps1
```

## Developer AWS authentication behavior

Authentication priority is deterministic:

1. If `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` are both configured in the runtime `.env`, they are used for AWS STS/SSM and, in Production, the host-side ECR bootstrap. `AWS_SESSION_TOKEN` is optional for temporary credentials. SSO values are not required in this mode.
2. If the static key pair is absent, IAM Identity Center is the fallback. Admin may stamp the non-secret SSO values into the exported Developer `.env.example`; `sandbox-aws-login` then completes corporate SSO/MFA in the Windows host browser.
3. A partial static credential configuration is an error and does not silently fall back to SSO.

When static credentials are selected, the container also creates a non-secret default/named AWS CLI compatibility configuration containing only region/output settings. `SANDBOX_AWS_PROFILE=sandbox` is not exported as the AWS CLI `AWS_PROFILE` environment variable. Therefore ordinary commands such as `aws sts get-caller-identity` use the static environment key pair directly. The config file contains no key value. No key value is written to `~/.aws/config`.

Static AWS credentials are runtime secrets. They are never build inputs and must not be committed. `run-with-ssm-secrets` removes them before leaf application children start after SSM retrieval. Claude, Gemini, `ucode claude`, and `ucode gemini` intentionally retain the AWS bootstrap pair in their process tree because their Admin-managed Tavily/Snyk/Databricks SQL MCP wrappers may start later and need AWS authentication to fetch their own SSM secrets.

### How MCP servers inherit AWS authentication (v1.16.16)

The two supported authentication modes reach an MCP child process by different routes, and both are now handled explicitly:

| Mode | How the MCP child obtains it | Requirement |
|------|------------------------------|-------------|
| Static key pair | Claude inherits the runtime pair normally. Gemini expands three explicit runtime references from its own process environment when starting the managed stdio MCP child. | Gemini MCP settings contain only literal `$AWS_ACCESS_KEY_ID`, `$AWS_SECRET_ACCESS_KEY`, and `$AWS_SESSION_TOKEN` references; never credential values. |
| IAM Identity Center SSO | File: token cache under `$SANDBOX_AWS_HOME/.aws/sso/cache` | Empty/unexpanded static references are removed by the MCP preamble and every AWS CLI call is pinned to `SANDBOX_AWS_HOME`. |

`SANDBOX_AWS_HOME` (default `/home/vscode`) is a stable anchor deliberately independent of `HOME`. It exists because `ucode claude`, `ucode gemini`, Tavily, Snyk and the Databricks SQL MCP bridge all execute under short-lived `HOME` directories, while the AWS CLI resolves its SSO token cache from `HOME` rather than from `AWS_CONFIG_FILE`. Without the anchor, SSO sessions are invisible to Databricks-routed agents and their MCP servers.

MCP registration is **credential-value-free** by construction. Claude Code user-scope entries contain only the approved wrapper command. Gemini requires a small `env` map because the CLI sanitizes inherited sensitive variables before launching stdio MCP children; v1.16.16 therefore stores only the three literal AWS runtime references shown above. It never stores an AWS access key, secret key, session token value, Tavily key, or Snyk token. `configure-mcp` preserves unrelated Gemini settings, replaces the three Admin-managed Tavily/Snyk/Databricks SQL entries deterministically, and fails closed if their env maps differ from the approved reference-only contract or if literal AWS access-key material is detected.

`ucode gemini` is handled separately because ucode launches Gemini with a managed `GEMINI_CLI_HOME`. The runtime resolves that managed home, runs `configure-mcp` against it after the temporary Databricks configuration is created, verifies the Tavily/Snyk/Databricks SQL entries, and then launches the routed Gemini session. The entire temporary ucode home is removed when the agent exits.

MCP stdio servers cannot display a device-code prompt: their stdout is the JSON-RPC channel. In SSO mode, run `sandbox-aws-login` in a VS Code terminal before first MCP tool use. Concurrent sign-in attempts are serialised with a lock, and a non-interactive context returns a clear instruction instead of hanging.

Developers can inspect effective non-secret runtime/build information with:

```bash
sandbox-info
```

## Responsibility boundary

Administrators own image hardening/builds, approved software, SSM parameter registration, Squid egress policy, ECR publication, Docker Desktop/Windows policy, and Developer package export. Runtime application audit controls remain part of the image and are not the same thing as removable release-evidence documents.
## Faster iterative builds

For wrapper, application, DevContainer, or Squid changes that do not require a new OS hardening baseline, v1.16.16 can reuse a previously built hardened base. Copy the previous `.build.env` into this package, or pass `-BuildEnvSource`, then run:

```powershell
pwsh -NoProfile -File .\scripts\admin\build-sandbox.ps1 -SandboxType POC -ReuseHardenedBase
```

Optional automatic copy from the previous package:

```powershell
pwsh -NoProfile -File .\scripts\admin\build-sandbox.ps1 `
  -SandboxType POC `
  -ReuseHardenedBase `
  -BuildEnvSource 'C:\path\to\previous-package\.build.env'
```

Reuse is fail-safe: `.build.env` must pass all normal validation, `BASE_IMAGE` and `SQUID_BASE_IMAGE` must be the same digest, and the exact image must carry the expected `hardening.method` and `hardening.profile=cis_level1_server` labels. If any check fails, the script automatically runs the normal resolver and hardened-base build.

Without `-ReuseHardenedBase`, the behavior remains the normal full hardening build.


## Optional AI content logging (v1.16.16)

Default:

```env
SANDBOX_CONTENT_LOGGING=false
```

When explicitly approved and set to `true`, the Sandbox writes separate content-bearing files under the existing host-exported `/var/log/sandbox` mount:

```text
claude-content.log         # bare claude: submitted prompt + final assistant response
gemini-content.log         # bare gemini: Gemini CLI API request/response telemetry/traces
ucode-claude-content.log   # ucode claude: Claude hook content, route=databricks-claude
ucode-gemini-content.log   # ucode gemini: Gemini CLI telemetry/traces through Databricks
```

The normal `*-events.log` files remain metadata-only. Content logging can capture source code, customer data, credentials accidentally pasted into prompts, system/tool context (Gemini traces), and model output. Treat these files as sensitive data, restrict host/Sentinel access, and define a shorter retention policy.

For Claude, the local hook captures the user-submitted prompt and the final assistant message exposed by Claude Code hooks; it is not a byte-for-byte capture of every provider wire request. For Gemini, the CLI's native telemetry can include `api_request.request_text`, `api_response.response_text`, and detailed trace input/output messages when content logging is enabled. `ucode` sessions are captured by the child Claude/Gemini agent and are tagged/routed to separate Databricks content files.


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
