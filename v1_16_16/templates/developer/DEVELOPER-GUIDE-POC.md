# AI Secure Sandbox v1.16.16 — Developer Guide (POC)

## 1. What you receive

This is a Developer runtime package only. Admin build/hardening source, Dockerfiles, security policy source, SSM setup scripts, Squid policy source and application-maintenance source are intentionally excluded.

The POC package contains only what is needed to load the approved two-image bundle and run it:

```text
.devcontainer/devcontainer.json
poc/docker-compose.yml
poc/images/*
scripts/poc/load-and-start.ps1/.sh
scripts/poc/verify-sandbox.ps1/.sh
.env.example
workspace/
DEVELOPER-GUIDE.md
```

## 2. First start on Windows 365

From PowerShell 7.4+ (`pwsh`) in the package root:

```powershell
Copy-Item .env.example .env
notepad .env
```

Set `DEVELOPER_ID` and the runtime values supplied by the platform team. For AWS authentication, use either the approved static AWS key pair or the IAM Identity Center (SSO) fallback values.

Do not put application/service tokens, PATs, passwords or API keys in `.env`. The only supported secret exception is the approved AWS bootstrap key pair when SSO cannot be used; protect `.env` as a local secret file and never commit it.

Start the approved POC images:

```powershell
.\scripts\poc\load-and-start.ps1
```

The launcher verifies bundle SHA-256 values, verifies the Admin runtime-policy hashes, loads the DevContainer and Squid TARs, validates the loaded image IDs and starts Docker Compose.

The host package `workspace/` directory is mounted inside the DevContainer at `/home/vscode/workspace`, owned/used by the non-root `vscode` user.

Then open the package root in VS Code and run:

```text
Dev Containers: Reopen in Container
```

## 3. AWS authentication — static key first, SSO fallback

Authentication priority is deterministic:

1. If `.env` contains both `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`, the Sandbox uses that pair for STS/SSM. `AWS_SESSION_TOKEN` is optional for temporary credentials. SSO values may be left blank in this mode.
2. If both static keys are absent, the Sandbox uses IAM Identity Center (SSO). The SSO Start URL, SSO Region, AWS account ID and role/permission-set role name must then be configured.
3. If only one static key is present, startup fails. It does not silently fall back to SSO.

When static credentials are selected, `sandbox-aws-login` only validates the STS identity; it does not start SSO. When SSO fallback is selected and the session is absent/expired, the wrapper starts the host-browser device authorization flow automatically.

You can inspect the selected mode without printing AWS key values:

```bash
sandbox-info
```

For direct STS troubleshooting in static-key mode:

```bash
env -u AWS_PROFILE -u AWS_DEFAULT_PROFILE aws sts get-caller-identity --region "$AWS_REGION"
```

For SSO fallback mode:

```bash
sandbox-aws-login
aws sts get-caller-identity --profile sandbox
```

`AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` are runtime bootstrap secrets when this mode is used. They are visible to the Developer/container runtime environment, so protect `.env`. For leaf commands, the SSM wrapper removes them after fetching the required SSM application secret. AI-agent sessions (`claude`, `gemini`, `ucode claude`, and `ucode gemini`) retain the AWS bootstrap pair in their process tree when static-key mode is used so Admin-managed Tavily/Snyk MCP wrappers can fetch their own SSM secrets later in the session.

## 4. Normal application commands

After AWS authentication, use the tools normally:

```bash
claude          # Anthropic official API
gemini          # Google Gemini official API
ucode claude    # Databricks AI Gateway; model from DATABRICKS_CLAUDE_MODEL
ucode gemini    # Databricks AI Gateway; model from DATABRICKS_GEMINI_MODEL
snyk test
databricks current-user me
```

The command name is the routing boundary: bare `claude`/`gemini` are direct-provider sessions, while `ucode claude`/`ucode gemini` are Databricks-routed sessions. The Sandbox creates a temporary PAT profile from `/sandbox/databricks-token`, runs `ucode configure --use-pat` non-interactively, and deletes the temporary ucode/Databricks auth state when the agent exits; browser login is not used. Tavily is MCP-first for Claude/Gemini. Direct troubleshooting remains available:

```bash
tvly search "query" --json
```

The public commands are Admin-controlled wrappers. At runtime they retrieve only the required SSM value and inject it only into the child process.


### MCP servers and AWS sign-in (v1.16.16)

Tavily and Snyk are exposed to Claude Code and Gemini CLI as MCP servers. Their registrations hold a command path and a start-up timeout only; no AWS key, no token and no `$VARIABLE` placeholder is ever written into MCP settings. Credentials are resolved when a tool is actually invoked.

If you use **static AWS keys**, nothing else is required: the MCP wrapper inherits them from your agent session.

If you use **IAM Identity Center SSO**, sign in once per session before your first MCP tool call:

```bash
sandbox-aws-login
```

An MCP server speaks JSON-RPC on stdout, so it cannot show you a device code itself. If the session is missing or expired, the MCP tool call fails immediately with an instruction to run `sandbox-aws-login` rather than hanging. After signing in, reconnect the MCP server (`/mcp` in Claude Code) or restart the agent session.

This applies equally to `ucode claude` and `ucode gemini`. Those run under a temporary HOME, but AWS state is pinned to `SANDBOX_AWS_HOME`, so a sign-in performed in any terminal is visible to Databricks-routed sessions and their MCP servers.

To confirm the registration is healthy:

```bash
verify-runtime | grep -i mcp
jq '.mcpServers' ~/.gemini/settings.json    # must contain no "env" key
```

## 5. See the effective Sandbox configuration

Use:

```bash
sandbox-info
```

This shows runtime routing, the selected AWS authentication mode, tool versions and native config locations without showing AWS key values or SSM secret values.

Useful native commands still work:

```bash
ucode status
ucode --version
databricks --version
claude --version
gemini --version
snyk --version
```

Important locations:

```text
/home/vscode/.aws/config                  AWS SSO profile (non-secret)
/home/vscode/.aws/sso/cache/              temporary SSO token cache
/home/vscode/.claude/                     Claude user state/config
/home/vscode/.gemini/                     Gemini user state/config
/home/vscode/.ucode/                      ucode state if ucode creates it
/etc/claude-code/managed-settings.json    Admin-managed Claude hooks (read-only)
/etc/ai-sandbox/build-info.json           image build provenance (read-only)
```

Databricks routing values such as `DATABRICKS_HOST` are Container environment values and can be seen with:

```bash
env | grep -E '^(DATABRICKS_|SANDBOX_AWS_PROFILE=|AWS_REGION=|SSM_PREFIX=|AWS_SSO_)'  # intentionally excludes AWS key values
```

## 6. Secret locations

Do not expect Databricks/Snyk/Tavily credentials in `~/.claude`, `~/.gemini`, `.env` or the workspace.

They are fetched from AWS SSM only when required. The core routes are:

```text
claude
 -> wrapper -> SSM /sandbox/claude-api-key
 -> ANTHROPIC_API_KEY in the Claude child process
 -> api.anthropic.com

gemini
 -> wrapper -> SSM /sandbox/gemini-api-key
 -> GEMINI_API_KEY in the Gemini child process
 -> generativelanguage.googleapis.com

ucode claude / ucode gemini
 -> wrapper -> SSM /sandbox/databricks-token
 -> DATABRICKS_TOKEN in the ucode process tree
 -> Databricks AI Gateway
```

`ucode` may manage Claude/Gemini user configuration for its routed sessions. The direct wrappers explicitly override provider base/auth environment values so a later bare `claude` or `gemini` invocation still means the official provider route.

## 7. Logging

The host log root contains:

```text
<log-root>/devcontainer/
<log-root>/squid/
```

Application audit records sanitized metadata such as application, operation category, status, exit code and duration. It intentionally excludes API keys, prompts/responses, source-code content, Tavily search text, Snyk findings and MCP request/response payloads.

## 8. What you can and cannot change

You can modify the workspace and approved user-level config volumes. You cannot modify the image-owned security/routing files under `/etc`, `/usr/local/bin` or `/usr/local/libexec/ai-sandbox` because the root filesystem is read-only and the container runs without sudo/capabilities.

If an Admin-managed URL, provider, wrapper, allowed destination or installed application version is wrong, report it to the Sandbox Admin; it must be corrected in the Admin source and released as a new approved image.

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


### v1.16.16: Databricks SQL MCP and managed Tavily search policy

- Claude and Gemini receive an additional `databricks-sql` MCP registration. The wrapper fetches `<SSM_PREFIX>/databricks-sql-mcp-token` at runtime and connects to `${DATABRICKS_HOST}/api/2.0/mcp/sql`; the PAT is not stored in MCP settings.
- Tavily MCP calls are enforced by the root-owned `/etc/ai-sandbox/tavily-allowed-domains.json` policy. Search without `include_domains` is automatically constrained to the Admin allowlist; an out-of-policy domain is denied.
- Claude managed settings deny native `WebSearch`/`WebFetch`; Gemini system policy denies `google_web_search`/`web_fetch`. Developers cannot edit the system policy files because they are root-owned and the container root filesystem is read-only.
- To change the allowed Tavily domains, the Admin edits `.devcontainer/policies/tavily-allowed-domains.json`, rebuilds the image, and redistributes/redeploys it.
