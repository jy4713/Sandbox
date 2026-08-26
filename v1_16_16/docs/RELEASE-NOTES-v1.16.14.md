# AI Secure Sandbox v1.16.14 — MCP connectivity and AWS authentication fix

Supersedes v1.16.13. This release fixes Tavily/Snyk MCP failures under Gemini CLI
(`gemini` and `ucode gemini`) and closes a credential-persistence defect in MCP
configuration.

---

## 1. Security action required before upgrading

v1.16.13 registered Gemini MCP servers with `gemini mcp add -e 'AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID' ...`.

Depending on the shell that executed `configure-mcp`, the value was either
expanded or not. Where it **was** expanded, live AWS access keys were written in
clear text into `~/.gemini/settings.json`.

**Before or immediately after upgrading:**

1. Inspect the file on every existing container and Cloud PC:

   ```bash
   jq '.mcpServers' ~/.gemini/settings.json
   grep -E '(AKIA|ASIA)[A-Z0-9]{16}' ~/.gemini/settings.json
   ```

2. If any `AKIA…`/`ASIA…` value is present, treat the corresponding IAM access
   key as **compromised**: deactivate and delete it in IAM, issue a replacement,
   and update the runtime `.env`.
3. Review CloudTrail for use of that access key ID outside the expected sandbox
   source IP range and time window.
4. Record the rotation in the change/incident register (REG pack) as required for
   the CNI security evidence set.

Running `configure-mcp` from v1.16.14 erases the credential block automatically,
but **erasure is not rotation**. The key must still be rotated, and the container
volume `ai-gemini` may retain prior file versions.

---

## 2. Defects fixed

### D-01 Credentials persisted into MCP configuration (security)

`configure-mcp.sh` wrote an `env` block containing AWS credentials into
`~/.gemini/settings.json`. MCP configuration is created during `post-create`,
before any AWS sign-in, so no credential can ever legitimately belong there.

**Fix.** The Gemini registration is written directly as JSON with `jq` and
contains a command path and timeout only. Any pre-existing `env` block on the
managed servers is dropped rather than merged, and the script fails closed if
credential-shaped material is detected afterwards.

### D-02 Unexpanded `$VARIABLE` placeholders broke IAM Identity Center auth

Where the shell did not expand the value, the literal string
`$AWS_ACCESS_KEY_ID` was injected into the MCP child. `run-with-ssm-secrets`
read that as a populated static key pair, selected static-credential mode,
failed STS validation, and then — by design — refused to fall back to SSO:

```
ERROR: static AWS environment credentials are configured but STS validation
       failed; SSO fallback is intentionally not attempted.
```

Every Gemini MCP start therefore failed in SSO mode, while Claude Code (which
never had an `env` block) worked.

**Fix.** Placeholder values beginning with `$` are discarded before credential
mode is selected, in `run-with-ssm-secrets.sh`, `sandbox-aws-login.sh`,
`configure-aws-sso.sh` and the shared MCP wrapper preamble. An empty
`AWS_SESSION_TOKEN` is also unset rather than sent to STS.

### D-03 SSO token cache unreachable from ephemeral HOME directories

The AWS CLI resolves its IAM Identity Center token cache from `HOME`
(`~/.aws/sso/cache`), not from `AWS_CONFIG_FILE`. `ucode claude` / `ucode gemini`
run the agent under `mktemp -d /tmp/ai-sandbox-ucode.XXXXXX`, so MCP servers
started inside a Databricks-routed session could not see a valid SSO session and
concluded it had expired.

**Fix.** A stable anchor `SANDBOX_AWS_HOME` (default `/home/vscode`) is
introduced and exported from both Compose files and the image. Every AWS CLI
invocation in `run-with-ssm-secrets` runs with `HOME` pinned to that anchor, and
`sandbox-aws-login` writes its token cache there.

### D-04 Interactive sign-in attempted inside an MCP stdio channel

On a missing session the runner called `sandbox-aws-login`, which starts a
device-code flow. Inside an MCP server that prompt is written to the JSON-RPC
channel, corrupting the protocol and blocking until the client times out.

**Fix.** `SANDBOX_NONINTERACTIVE=1` is set by both MCP wrappers, and both the
runner and the login script refuse interactive sign-in in that context (or where
stdin is not a TTY), returning an actionable message instead. `post-create` now
prompts the developer to pre-warm the SSO session in SSO mode.

### D-05 Concurrent sign-in race

An agent and its Tavily/Snyk MCP servers can detect expiry simultaneously and
each start a device-code flow, racing on `~/.aws/sso/cache`.

**Fix.** `sandbox-aws-login` serialises through `flock` on
`$SANDBOX_AWS_HOME/.aws/.sso-login.lock` and re-checks identity under the lock.

### D-06 Snyk MCP could not start within its timeout

`run_logged_snyk_exec_home` creates a fresh exec-enabled tmpfs HOME per
invocation and redirects `XDG_CACHE_HOME` into it, bypassing the persistent
`~/.cache` volume. The Snyk CLI therefore re-downloaded its versioned native
executable on every MCP start. The build-time warm-up ran as `root` and was not
reachable at runtime.

**Fix.** The image bakes a read-only warmed cache at `/opt/snyk-cache`, which is
copied into the ephemeral exec tmpfs on each invocation.

### D-07 MCP start-up timeout too short

Registrations used `timeout: 10000` (10 s). A wrapper must complete an STS
identity check and an SSM `get-parameter` round trip through Squid before the MCP
server starts.

**Fix.** Tavily 120 s, Snyk 180 s.

### D-08 `gemini mcp add` argument parsing

The repeatable `-e/--env` option is array-typed and can consume the trailing
positional `name` and `commandOrUrl` arguments depending on CLI version, silently
producing a malformed registration.

**Fix.** `gemini mcp add` is no longer used for registration. `gemini mcp remove`
is still used to clear stale entries from earlier versions.

### D-09 Audit failure aborted the MCP server

`application-audit --event server_start` ran under `set -e` without `|| true`.
Where `/var/log/sandbox` was not writable — a common host bind-mount ownership
issue on Windows 365 — the wrapper exited before the MCP handshake.

**Fix.** Lifecycle audit calls in the wrappers are non-fatal. The
audit-required policy continues to be enforced centrally in
`run-with-ssm-secrets`, which is the correct enforcement point.

### D-10 MCP child environment not self-sufficient

If an MCP client replaces rather than merges the child environment, the wrapper
loses `PATH`, proxy variables and SSM settings, and fails before the handshake
with an opaque error.

**Fix.** New sourced fragment
`/usr/local/libexec/ai-sandbox/mcp-wrapper-preamble` establishes a deterministic
non-secret environment for every MCP wrapper. It contains no secret and writes
nothing to stdout.

---

## 3. Changed files

| File | Change |
|------|--------|
| `.devcontainer/scripts/configure-mcp.sh` | Rewritten: deterministic `jq` write, no `env` block, credential self-check, raised timeouts |
| `.devcontainer/scripts/mcp-wrapper-preamble.sh` | **New** — shared non-secret environment for MCP wrappers |
| `.devcontainer/scripts/tavily-mcp-ssm.sh` | Sources preamble, non-fatal lifecycle audit |
| `.devcontainer/scripts/snyk-mcp-ssm.sh` | Sources preamble, non-fatal lifecycle audit, safe empty-array handling |
| `.devcontainer/scripts/run-with-ssm-secrets.sh` | `SANDBOX_AWS_HOME` anchor, placeholder sanitisation, non-interactive guard, Snyk cache seeding, anchor propagation into agent trees |
| `.devcontainer/scripts/sandbox-aws-login.sh` | HOME pinning, `flock` serialisation, non-interactive guard |
| `.devcontainer/scripts/configure-aws-sso.sh` | Config path pinned to the anchor, placeholder sanitisation |
| `.devcontainer/scripts/verify-runtime.sh` | New MCP secret-hygiene, timeout, preamble, Snyk cache and AWS reachability checks |
| `.devcontainer/Dockerfile` | `util-linux` (flock), `/opt/snyk-cache` warm-up, preamble install, anchor defaults |
| `poc/docker-compose.yml`, `ecr/docker-compose.yml` | `SANDBOX_AWS_HOME`, `SANDBOX_HTTPS_PROXY` |
| `.devcontainer/post-create.sh` | SSO pre-warm guidance |
| `scripts/ci/lint-package.sh` / `.ps1` | Matching rules for every change above |
| `README.md`, both developer guides | Documented MCP/AWS contract |

Squid allowlist, SSM parameter names, the dual-identity model and the audit
schema are unchanged. No new egress domain is required.

---

## 4. Verification

### Build side

```powershell
pwsh ./scripts/ci/lint-package.ps1
pwsh ./scripts/admin/build-sandbox.ps1
```

```bash
bash scripts/ci/lint-package.sh
```

### Runtime side

```bash
verify-runtime
```

Expected new lines:

```
[OK] Gemini MCP registration carries no env block
[OK] no AWS credential material in Gemini MCP settings
[OK] no unexpanded placeholders in Gemini MCP settings
[OK] Gemini MCP start-up budget allows SSM credential resolution
[OK] MCP wrapper environment preamble is installed
[OK] Snyk native runtime cache is pre-warmed in the image
[OK] AWS state anchor is configured
[OK] AWS CLI state is reachable independently of HOME
```

### Functional matrix

| Case | Command | Expected |
|------|---------|----------|
| Static keys, direct | `gemini` → Tavily tool | Success |
| Static keys, Databricks | `ucode gemini` → Snyk tool | Success |
| SSO, direct | `sandbox-aws-login` then `gemini` | Success |
| SSO, Databricks | `sandbox-aws-login` then `ucode gemini` | Success (failed in v1.16.13) |
| SSO expired mid-session | invoke any MCP tool | Clear instruction, no hang |
| Partial static keys | start any agent | Fails without SSO fallback (policy unchanged) |
| Upgrade from v1.16.13 | `configure-mcp` | Credential block erased |

---

## 5. Rollout

1. Rotate any AWS access key found in `~/.gemini/settings.json` (section 1).
2. Rebuild the DevContainer image; `-ReuseHardenedBase` / `--reuse-hardened-base`
   remains valid since no hardening input changed.
3. Re-export the Developer packages and push to ECR if applicable.
4. Developers recreate their container so the new tmpfs and image defaults apply.
   Reusing a v1.16.13 container leaves the stale `ai-gemini` volume in place;
   `configure-mcp` scrubs it on first `post-create`, but a fresh container is
   preferred for evidence purposes.
5. In SSO mode, developers run `sandbox-aws-login` before first MCP tool use.
