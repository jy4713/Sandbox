# AI Secure Sandbox v1.16.16 — Security Boundary, Audit Logging and Sentinel


> Windows PowerShell examples in this baseline are intended to run with PowerShell 7.4+ (`pwsh`).

## 0. Runtime security boundary

The Developer package is a runtime configuration package, not the only security boundary. Production assurance is layered:

```text
Windows 365 / endpoint controls
  -> Docker Desktop Business centrally managed policy / ECI
  -> two-container Docker network isolation
  -> DevContainer read-only/non-root/cap-drop/no-new-privileges
  -> Squid default-deny egress
  -> SSM process-scoped credentials
  -> host-exported audit logs
  -> AMA or Logs Ingestion API -> Log Analytics/Sentinel
```

Developer-editable Compose files must therefore be protected by managed-host ACL/policy in Production. The Sandbox does not mount the Docker socket and the DevContainer is connected only to the Docker `internal` network; Squid is the only Sandbox service attached to the external bridge.

AWS authentication is dual-mode with a deterministic priority: a complete runtime `AWS_ACCESS_KEY_ID` + `AWS_SECRET_ACCESS_KEY` pair is used first for STS/SSM (and Production ECR bootstrap), while IAM Identity Center/SSO is the fallback when the static pair is absent. `AWS_SESSION_TOKEN` is supported for temporary credentials. Static AWS bootstrap credentials are runtime secrets and must not be committed; a partial or invalid configured pair does not silently fall back to SSO. In static-key mode, a non-secret named-profile compatibility stub may be written to `~/.aws/config` so ordinary AWS CLI commands do not fail on a missing named profile; the Access Key and Secret Access Key themselves are never written to that file.

---


## 1. Purpose

The Sandbox runtime deliberately contains only two containers:

```text
DevContainer
Squid Proxy
```

There is no in-Sandbox log-forwarding sidecar.

The Sandbox is responsible for generating logs and exporting them to a host-visible directory. The Windows 365 / Security platform is responsible for collecting, authenticating, forwarding, retaining, and alerting on those logs.

Supported forwarding patterns in this package are:

- **Option 2 - Azure Monitor Agent (AMA) + Data Collection Rule (DCR)**
- **Option 3 - Windows host sender + Azure Monitor Logs Ingestion API + DCR**

The forwarding choice can be changed without rebuilding the DevContainer or Squid images, as long as the same host log files remain available.

---

## 2. Host Log Layout

Recommended managed Windows 365 path:

```text
C:\ProgramData\AI-Sandbox\Logs\
├── devcontainer\
│   ├── audit.log
│   ├── security.log
│   ├── claude-events.log
│   ├── anthropic-events.log
│   ├── gemini-telemetry.log
│   ├── gemini-events.log
│   ├── databricks-events.log
│   ├── tavily-events.log
│   ├── snyk-events.log
│   ├── ado-events.log
│   ├── git-events.log
│   ├── hiddenlayer-events.log
│   └── mcp-events.log
└── squid\
    └── access.log
```

Runtime `.env`:

```env
SANDBOX_LOG_ROOT=C:/ProgramData/AI-Sandbox/Logs
```

For a standalone POC, `SANDBOX_LOG_ROOT` can be left blank. The Developer launcher then uses a package-local `logs` directory.

Compose mappings:

```text
DevContainer /var/log/sandbox -> <SANDBOX_LOG_ROOT>/devcontainer
Squid        /var/log/squid   -> <SANDBOX_LOG_ROOT>/squid
```

No Sentinel or Log Analytics credential is injected into either container.

## 2.1 Log Sources

The host-exported files intentionally separate security/audit metadata from raw AI conversation history:

| File | Source | Purpose | Content policy |
|---|---|---|---|
| `devcontainer/audit.log` | Sandbox shell audit hook | Session and shell command attribution | Metadata only: tool/subcommand/argument count; arbitrary command arguments are not copied |
| `devcontainer/security.log` | Sandbox shell audit hook | Higher-risk security events | Structured metadata only; raw suspicious commands are not copied |
| `devcontainer/claude-events.log` | Admin-managed Claude Code command hooks | Claude session lifecycle, prompt length, tool names, success/failure lifecycle metadata | Prompt text, assistant text, tool input/output and transcript content are deliberately excluded |
| `devcontainer/anthropic-events.log` | SSM runtime wrapper | Direct Claude credential-fetch/process lifecycle against the Anthropic API | No Claude API key, prompt, response or raw command arguments |
| `devcontainer/gemini-telemetry.log` | Gemini CLI native local telemetry | Gemini session/tool/API usage telemetry | `GEMINI_TELEMETRY_LOG_PROMPTS=false`; review tool metadata classification before Production ingestion |
| `devcontainer/gemini-events.log` | SSM runtime wrapper | Direct Gemini credential-fetch/process lifecycle against the Google Gemini API | No Gemini API key, prompt, response or raw command arguments |
| `devcontainer/databricks-events.log` | SSM runtime wrapper | Databricks credential/ucode/CLI lifecycle | No Databricks token, prompt, response or raw command arguments |
| `devcontainer/tavily-events.log` | SSM runtime wrapper | Tavily CLI/MCP operation lifecycle | Operation category only; search query and results excluded |
| `devcontainer/snyk-events.log` | SSM runtime wrapper | Snyk CLI/MCP operation lifecycle | Scan findings and source-code content excluded |
| `devcontainer/ado-events.log` | SSM runtime wrapper | ADO/Git/PR/pipeline helper lifecycle | PAT/SP secrets, PR bodies, pipeline parameters and full command arguments excluded |
| `devcontainer/git-events.log` | Interactive Git shell wrapper | Git operation lifecycle | Remote URLs and complete command arguments excluded |
| `devcontainer/hiddenlayer-events.log` | SSM runtime wrapper | HiddenLayer integration lifecycle | Credentials and request/response payloads excluded |
| `devcontainer/mcp-events.log` | MCP wrappers | Tavily/Snyk MCP server lifecycle | MCP request/response payloads excluded |
| `squid/access.log` | Squid | Approved/denied egress activity | Proxy request metadata |

Claude Code audit hooks are baked into the image through `/etc/claude-code/managed-settings.json` and write through `/usr/local/bin/claude-audit-hook`. The hook uses a strict metadata allowlist so that normal prompt and response content is not copied into the Sentinel feed.

Gemini CLI local telemetry is enabled through container environment variables and writes directly to `/var/log/sandbox/gemini-telemetry.log`. Prompt content is explicitly disabled. Gemini telemetry may still contain operational tool metadata such as function/tool names and arguments, so the Security team must review table access, retention, and data classification before Production onboarding.

The package does **not** bind-mount the complete `~/.claude` or `~/.gemini` configuration/session directories to the Windows host. This avoids exporting AI credentials/configuration merely for monitoring.

### 2.2 Application audit policy

SSM-backed application wrappers use `/usr/local/bin/application-audit` to write structured JSON metadata. `SANDBOX_AUDIT_REQUIRED=true` is the default; if the application audit start event cannot be written, the secret-backed application does not start. See `docs/SECURITY-LOGGING-AND-SENTINEL.md`.

---

# 3. Option 2 - Azure Monitor Agent (AMA)

## 3.1 Responsibility

AMA installation, DCR creation, DCR association, endpoint management, Log Analytics table creation, and Sentinel onboarding are owned by the Windows/Azure/Security platform team.

The Sandbox package only prepares the host files that AMA can collect.

## 3.2 Prepare the Host Folder

Run as an Administrator on the Windows 365 VM:

```powershell
.\scripts\platform\03-setup-logging.ps1 `
  -Mode AMA `
  -LogRoot 'C:\ProgramData\AI-Sandbox\Logs'
```

Set the Developer runtime `.env`:

```env
SANDBOX_LOG_ROOT=C:/ProgramData/AI-Sandbox/Logs
```

## 3.3 Suggested AMA File Patterns

```text
C:\ProgramData\AI-Sandbox\Logs\devcontainer\*.log
C:\ProgramData\AI-Sandbox\Logs\squid\*.log
```

Suggested custom table:

```text
AISandboxHostLogs_CL
```

The package provides an example DCR body:

```text
sentinel/dcr-ama-custom-text.example.json
```

Replace the placeholders with values supplied by the Azure/Security team before using it.

The example follows the custom text log model:

```text
stream declaration
      +
logFiles data source
      +
Log Analytics destination
      +
data flow
```

The target machine must be managed in a way supported by the client's Azure Monitor Agent architecture. If the Windows 365 Cloud PC cannot be directly associated with the required DCR in the client's environment, use the organization's approved connected-machine or centralized collection architecture instead. This decision is outside the Sandbox image.

---

# 4. Option 3 - Azure Monitor Logs Ingestion API

## 4.1 Responsibility

A host-side process reads the exported files and posts records to the Azure Monitor Logs Ingestion API.

The package contains reference senders:

```text
scripts/monitoring/send-logs-ingestion.ps1
scripts/monitoring/send-logs-ingestion.sh
```

These scripts are not started by Docker Compose and are not copied into the DevContainer image.

For Production, run the sender as an Admin-managed Windows service, Scheduled Task, endpoint-management package, or equivalent approved mechanism.

## 4.2 Required Azure Components

The Azure/Security team provides:

1. Log Analytics workspace.
2. Custom table, for example `AISandboxHostLogs_CL`.
3. DCR for direct log ingestion.
4. DCR logs ingestion endpoint, or DCE when required by the network/private-link design.
5. DCR immutable ID.
6. DCR stream name.
7. Microsoft Entra application/service principal or another approved sender identity.
8. Required permission on the DCR.

For an Entra application, the standard Azure Monitor pattern is to assign **Monitoring Metrics Publisher** on the DCR, or an equivalent custom role containing the required telemetry write data action.

## 4.3 Reference DCR

The package provides:

```text
sentinel/dcr-logs-ingestion.example.json
```

Default reference stream:

```text
Custom-AISandboxHostLogs
```

Incoming schema:

```json
[
  {
    "Time": "2026-08-17T12:00:00Z",
    "RawData": "example sandbox log line"
  }
]
```

Reference transform:

```kusto
source
| project TimeGenerated=todatetime(Time), RawData
```

Target table:

```text
AISandboxHostLogs_CL
```

## 4.4 Reference Windows Sender

For a POC test only, a client secret can be supplied temporarily through an environment variable:

```powershell
$env:AZURE_CLIENT_SECRET = '<temporary-test-secret>'

.\scripts\monitoring\send-logs-ingestion.ps1 `
  -LogRoot 'C:\ProgramData\AI-Sandbox\Logs' `
  -Endpoint 'https://<logs-ingestion-endpoint>' `
  -DcrImmutableId 'dcr-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx' `
  -StreamName 'Custom-AISandboxHostLogs' `
  -TenantId '<tenant-id>' `
  -ClientId '<client-id>'

Remove-Item Env:AZURE_CLIENT_SECRET -ErrorAction SilentlyContinue
```

The sender uses the REST path:

```text
<endpoint>/dataCollectionRules/<dcr-immutable-id>/streams/<stream-name>?api-version=2023-01-01
```

The body is a JSON array matching the DCR input stream.

## 4.5 Optional POC Secret from AWS SSM

If the host already has an approved AWS identity for POC testing, the reference sender can retrieve its Entra application secret from an AWS SSM SecureString:

```powershell
.\scripts\monitoring\send-logs-ingestion.ps1 `
  -LogRoot 'C:\ProgramData\AI-Sandbox\Logs' `
  -Endpoint 'https://<logs-ingestion-endpoint>' `
  -DcrImmutableId 'dcr-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx' `
  -TenantId '<tenant-id>' `
  -ClientId '<client-id>' `
  -ClientSecretSsmParameter '/sandbox/monitoring/azure-client-secret' `
  -AwsProfile sandbox `
  -AwsRegion eu-west-2
```

This parameter is intentionally **not** created by `01-setup-ssm.*`. Monitoring credentials are owned by the endpoint/security platform, not by the application SSM bootstrap.

For Production, use the organization's approved host credential method and rotation policy rather than embedding a secret in the Developer package.

---

# 5. Verify Container-to-Host Log Export

After the Sandbox starts, verify that a record written in the DevContainer is visible on the host.

POC:

```powershell
.\scripts\monitoring\verify-host-log-export.ps1 `
  -ComposeFile '.\poc\docker-compose.yml' `
  -LogRoot 'C:\ProgramData\AI-Sandbox\Logs'
```

Production runtime directory example:

```powershell
.\monitoring\verify-host-log-export.ps1 `
  -ComposeFile '.\docker-compose.yml' `
  -LogRoot 'C:\ProgramData\AI-Sandbox\Logs'
```

This check proves only:

```text
Container -> Host log file
```

It does not prove Sentinel ingestion.

After a new v1.16.16 image is running, additional functional checks are recommended:

```powershell
Get-Content 'C:\ProgramData\AI-Sandbox\Logs\devcontainer\claude-events.log' -Tail 20
Get-Content 'C:\ProgramData\AI-Sandbox\Logs\devcontainer\gemini-telemetry.log' -Tail 20
Get-Content 'C:\ProgramData\AI-Sandbox\Logs\squid\access.log' -Tail 20
```

`claude-events.log` should be populated by Claude lifecycle/tool hooks after Claude Code is used. `gemini-telemetry.log` should be populated by Gemini CLI after Gemini is used.

---

# 6. Verify Sentinel Ingestion

After Option 2 or Option 3 has been configured, query the target workspace:

```kusto
AISandboxHostLogs_CL
| where TimeGenerated > ago(30m)
| order by TimeGenerated desc
```

The Security/Azure team should also send a unique acceptance marker and verify that the same marker is visible in the target Log Analytics table used by Microsoft Sentinel.

---

# 7. Security Boundary

```text
Sandbox containers
    |
    | generate logs only
    v
Host-mounted protected directory
    |
    +--> Option 2: AMA + DCR
    |
    `--> Option 3: Admin-managed API sender + DCR
             |
             v
       Log Analytics
             |
             v
       Microsoft Sentinel
```

The Sandbox start workflow does not depend on Sentinel being configured. If forwarding is not configured, the Sandbox can still run and the logs remain on the host.

## Tamper-Resistance Note

A host-visible bind mount improves separation between the Sandbox runtime and the SIEM forwarding process, but it does not by itself make the log files immutable. Production endpoint design should apply appropriate Windows ACLs, centralized collection latency, retention, and endpoint security controls according to the client's threat model.

## Optional prompt/response content logging

Content logging is **disabled by default**:

```env
SANDBOX_CONTENT_LOGGING=false
```

Only enable it after Security/Data Privacy approval. When enabled, the existing host bind mount carries the following additional files:

| Command | Route | Content file | Capture mechanism |
|---|---|---|---|
| `claude` | Anthropic direct | `claude-content.log` | Claude Code `UserPromptSubmit` + `Stop` hook fields |
| `gemini` | Google direct | `gemini-content.log` | Gemini CLI local OpenTelemetry API request/response + detailed traces |
| `ucode claude` | Databricks AI Gateway | `ucode-claude-content.log` | child Claude Code hooks with `route=databricks-claude` |
| `ucode gemini` | Databricks AI Gateway | `ucode-gemini-content.log` | child Gemini CLI OpenTelemetry with Databricks routing |

The existing `anthropic-events.log`, `gemini-events.log`, `databricks-events.log`, `claude-events.log`, and other application audit files remain metadata-only regardless of this flag.

Content files are placed in the nested `devcontainer/content/` directory on the Windows host. The package's existing top-level `devcontainer\*.log` Sentinel examples do not intentionally include that nested directory. Forward content logs only through a separately approved DCR/table and retention policy.

### Data sensitivity

The content files can contain source code, customer/confidential information, personal data, credentials accidentally pasted by a Developer, model responses, system instructions, and tool context. Do not forward them into the same Sentinel table/retention policy as metadata logs without an explicit data-handling decision. Recommended controls are a separate DCR/table or exclusion rule, restricted RBAC, encryption at rest, and a deliberately short retention period.

### Capture limitations

Claude Code hooks expose the submitted user prompt and the final assistant message; this is not a full raw HTTP/API wire capture of all internal system/tool messages. Gemini CLI telemetry provides richer API request/response fields and detailed GenAI traces when enabled. For `ucode`, the local content is captured by the actual Claude/Gemini child agent and separated by route; Databricks server-side inference logging, if enabled separately by the platform team, remains an independent control.
