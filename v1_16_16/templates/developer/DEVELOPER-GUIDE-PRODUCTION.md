# AI Secure Sandbox v1.16.16 — Developer Guide (Production)

## 1. What you receive

This is a minimal Production runtime package. Build/hardening source, Dockerfiles, Squid policy source, SSM bootstrap scripts and Admin application-maintenance code are not distributed to Developers.

## 2. One-time local setup

From PowerShell 7.4+ (`pwsh`) in the approved Windows 365 runtime directory:

```powershell
Copy-Item .env.example .env
notepad .env
```

Set `DEVELOPER_ID` and the assigned runtime values. For AWS authentication, use either the approved static AWS key pair or the IAM Identity Center (SSO) fallback values.

Do not place PATs, application API keys, passwords or application tokens in `.env`. The only supported secret exception is the approved AWS bootstrap key pair when SSO cannot be used; protect `.env` as a local secret file and never commit it.

## 3. Production start — static key first, host-browser SSO fallback

Run:

```powershell
.\scripts\ecr\pull-and-start.ps1
```

AWS authentication priority:

1. If `.env` contains both `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`, the launcher uses them for host-side STS/SSM/ECR. `AWS_SESSION_TOKEN` is optional. SSO values are not required. The startup flow does not export AWS_PROFILE in static-key mode. The static environment key pair is therefore the AWS CLI credential source. A non-secret default/named config containing only region/output settings may be created for CLI consistency.
2. If the static pair is absent, the launcher uses IAM Identity Center and the Windows-host browser flow.
3. A partial static credential pair is rejected.

The launcher:

1. selects static AWS credentials when the complete key pair is present, otherwise generates/refreshes the non-secret `sandbox` SSO profile;
2. validates the selected AWS identity with STS;
3. in SSO fallback mode only, opens the **Windows host browser** for corporate SSO/MFA when required;
4. falls back to device-code login if automatic browser launch is unavailable;
5. reads the centrally approved image manifest and SHA-256 from AWS SSM;
6. validates registry/repository/digest shape;
7. logs Docker in to ECR;
8. pulls the exact approved DevContainer and Squid digests;
9. creates the fixed local runtime aliases used by Compose/VS Code;
10. starts/recreates the two-container Sandbox.

Developers do not need to run `aws configure sso` or remember SSO Start URL/Region/Account/Role.

The host package `workspace/` directory is mounted inside the DevContainer at `/home/vscode/workspace`, owned/used by the non-root `vscode` user.

## 4. VS Code / DevContainer AWS authentication

After the stack starts, open the package root in VS Code and run:

```text
Dev Containers: Reopen in Container
```

The DevContainer receives the same runtime AWS authentication inputs. A complete static key pair takes priority; otherwise the non-secret SSO fallback values are used.

When `claude`, `gemini`, `ucode`, `snyk`, `databricks` or Tavily first requires SSM, the wrapper checks the same priority. With a valid static key pair it uses STS/SSM directly and does not launch SSO. If the static pair is absent and the DevContainer SSO session is missing, the wrapper automatically launches:

```bash
sandbox-aws-login
```

In SSO fallback mode, the terminal displays a verification URL and code to complete in the **Windows host browser**. This is intentionally a device authorization flow because the CLI is inside Linux while the browser is on Windows. In static-key mode no browser login occurs.

## 5. Normal application use

```bash
claude          # Anthropic official API
gemini          # Google Gemini official API
ucode claude    # Databricks AI Gateway; model from DATABRICKS_CLAUDE_MODEL
ucode gemini    # Databricks AI Gateway; model from DATABRICKS_GEMINI_MODEL
snyk test
databricks current-user me
```

The command name is the routing boundary: bare `claude`/`gemini` are direct-provider sessions, while `ucode claude`/`ucode gemini` are Databricks-routed sessions. The Sandbox creates a temporary PAT profile from `/sandbox/databricks-token`, runs `ucode configure --use-pat` non-interactively, and deletes the temporary ucode/Databricks auth state when the agent exits; browser login is not used. Tavily is registered as an MCP server for Claude/Gemini. Direct CLI troubleshooting:

```bash
tvly search "query" --json
```


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

## 6. Configuration inspection without the Admin package

Run:

```bash
sandbox-info
```

This exposes runtime routing, build provenance and the selected AWS authentication mode. It does not print AWS key values or SSM secret values.

Native checks:

```bash
ucode status
ucode --version
databricks --version
claude --version
gemini --version
snyk --version
```

Configuration locations:

```text
/home/vscode/.aws/config                  AWS SSO profile
/home/vscode/.aws/sso/cache/              temporary SSO token cache
/home/vscode/.claude/                     Claude user config/state
/home/vscode/.gemini/                     Gemini user config/state
/home/vscode/.ucode/                      ucode state if created
/etc/claude-code/managed-settings.json    Admin-managed hooks/policy
/etc/ai-sandbox/build-info.json           read-only build provenance
```

Drax runtime routing values are Container environment variables:

```bash
env | grep -E '^(DATABRICKS_|SANDBOX_AWS_PROFILE=|AWS_REGION=|SSM_PREFIX=|AWS_SSO_)'  # intentionally excludes AWS key values
```

## 7. Secret handling

Application SSM-backed secrets are not persisted in `.env`, user config or the workspace; they are injected into the approved child process only when the command runs. Static AWS bootstrap credentials are the explicit `.env` exception when SSO is unavailable. Leaf application children have the AWS bootstrap pair removed after their SSM fetch. AI-agent sessions (`claude`, `gemini`, `ucode claude`, and `ucode gemini`) retain it in their process tree so the Admin-managed Tavily/Snyk MCP wrappers can authenticate to SSM when those MCP servers start later in the session.

Provider secret mapping:

```text
claude       -> /sandbox/claude-api-key -> Anthropic official API
gemini       -> /sandbox/gemini-api-key -> Google Gemini official API
ucode ...    -> /sandbox/databricks-token -> Databricks AI Gateway
databricks   -> /sandbox/databricks-token -> Databricks workspace API
```

`ucode` can maintain agent routing files in the normal user configuration directories. The bare-command wrappers force direct provider environment values at launch so `claude` and `gemini` do not inherit a Databricks gateway route from an earlier ucode session.

## 8. Host logging

The Production launcher creates the configured host log directory with:

```text
devcontainer/
squid/
```

Host/Sentinel forwarding is owned by the Windows/Security platform; no monitoring sidecar runs in the Sandbox.

## 9. Runtime changes

Developer-owned workspace/user settings can be changed. Admin-managed routing, installed versions, wrappers, Squid allowlist and security policy require an Admin image release.

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
