# AI Secure Sandbox v1.16.15 — Release Notes

## Scope

v1.16.15 is a focused compatibility and verification fix over v1.16.14. It does not change the two-container security architecture, the SSM secret model, the default-deny Squid policy, or the direct-vs-Databricks command routing.

## Fixed: Direct Gemini MCP with static AWS credentials

Gemini CLI sanitizes inherited sensitive environment variables before starting stdio MCP servers. In v1.16.14 this meant that a direct Gemini session could authenticate to Google successfully, while its Tavily/Snyk MCP wrappers lost `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` and disconnected before they could read their service credentials from SSM.

v1.16.15 writes an explicit **runtime reference only** env block for the two Admin-managed Gemini MCP servers:

```json
{
  "AWS_ACCESS_KEY_ID": "$AWS_ACCESS_KEY_ID",
  "AWS_SECRET_ACCESS_KEY": "$AWS_SECRET_ACCESS_KEY",
  "AWS_SESSION_TOKEN": "$AWS_SESSION_TOKEN"
}
```

These are literal references, not AWS credential values. The configuration self-check fails closed if the managed env block contains anything other than these references or if a literal AWS access-key ID is detected.

### Static-key mode

At MCP launch, Gemini expands the references from the running process environment. The SSM wrapper uses the runtime AWS pair to call STS/SSM, fetches the Tavily/Snyk service credential, then removes AWS bootstrap credentials before launching the vendor MCP process.

### IAM Identity Center SSO mode

When static AWS variables are absent, the MCP preamble removes empty or unexpanded references. `run-with-ssm-secrets` then uses the stable `SANDBOX_AWS_HOME` state anchor and IAM Identity Center token cache. MCP stdio remains non-interactive; if the SSO session is expired, the developer must run `sandbox-aws-login` in a VS Code terminal.

## Fixed: `ucode gemini` had no MCP servers

ucode isolates Gemini under a managed `GEMINI_CLI_HOME` rather than using the normal `$HOME/.gemini/settings.json`. v1.16.14 recreated MCP definitions in the temporary ucode HOME but did not target ucode's managed Gemini home, so `ucode gemini` could report `No MCP servers configured` even though `ucode claude` worked.

v1.16.15:

1. Resolves ucode's managed Gemini home from the installed `ucode.agents.gemini.GEMINI_HOME_DIR` when possible.
2. Falls back to the currently supported `$HOME/.ucode/.gemini-home` layout if introspection is unavailable.
3. Runs `configure-mcp` with `GEMINI_CLI_HOME` set to that temporary managed home.
4. Verifies the generated Tavily/Snyk entries before launching `ucode gemini` and fails closed if they are missing.
5. Deletes the complete temporary ucode home after the agent exits as before.

## Fixed: Windows POC verifier `$Args` collision

`verify-sandbox.ps1` used a function parameter named `$Args`, which conflicts with PowerShell's automatic `$args` variable. Docker Compose subcommands could therefore be lost and many checks incorrectly failed while printing Docker Compose help text.

The helper now uses `$DockerArgs`:

```powershell
function Dc([string[]]$DockerArgs){ & docker compose -f $Compose @DockerArgs }
```

Package lint now guards against regression to `$Args`.

## Verification changes

`verify-runtime` no longer expects Gemini MCP to have no env block. It now verifies that:

- Tavily and Snyk commands point to the approved SSM wrappers.
- Their env maps exactly match the three approved AWS runtime references.
- No literal AWS access-key ID is stored in Gemini settings.
- The ucode Gemini path is wired through managed `GEMINI_CLI_HOME` discovery/configuration.
- Existing AWS static-first / SSO-fallback and non-interactive MCP rules remain present.

Bash and PowerShell package lints were updated with the same contracts.

## Vendor versions

No vendor CLI version was intentionally changed in this focused fix. In particular, `GEMINI_CLI_VERSION` remains `0.53.0` from the v1.16.14 baseline. The MCP failure was caused by environment/config-home behavior, not by the absence of Gemini 0.56. Keeping the existing pin avoids combining an unvalidated agent/model-routing upgrade with this security fix.

## Recommended smoke test

After rebuilding/reloading v1.16.15 and reopening the Dev Container:

```bash
verify-runtime

gemini mcp list
claude mcp list
```

Expected direct Gemini result:

```text
snyk   ... Connected
tavily ... Connected
```

Then validate Databricks-routed sessions:

```bash
ucode claude
# /mcp list

ucode gemini
# /mcp list
```

Both agents should show Tavily and Snyk. Test once with static AWS credentials and once with static AWS variables removed after completing `sandbox-aws-login`.
