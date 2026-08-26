# AI Secure Sandbox v1.16.16 Release Notes

## Added

- Managed Databricks SQL MCP registration (`databricks-sql`) for Claude Code, Gemini CLI, `ucode claude`, and `ucode gemini`.
- Dedicated SSM SecureString path `<SSM_PREFIX>/databricks-sql-mcp-token`; it may contain the same PAT as `databricks-token` during POC but remains independently addressable.
- Pinned `mcp-remote` bridge used only behind the Admin-managed Databricks SQL wrapper.
- Root-owned Tavily domain allowlist and fail-closed MCP stdio proxy.
- Claude managed policy disables native WebSearch/WebFetch and adds Tavily PreToolUse guard hooks.
- Gemini Admin-tier policy disables native Google web search/web fetch.

## Security behavior

- Tavily search without `include_domains` is constrained to the full Admin allowlist.
- Tavily search requesting a non-approved domain is rejected before it reaches Tavily.
- Tavily extract/crawl/map are limited to approved HTTPS domains; unconstrained Tavily research is disabled.
- Caller-supplied `DEFAULT_PARAMETERS` is cleared on the Tavily MCP path so it cannot overwrite the Admin proxy decision.
- Databricks SQL PAT is fetched only by the dedicated SSM runner profile and is passed to `mcp-remote` through an environment reference, not MCP settings or argv.
- Policy files are root-owned and become immutable with the existing read-only container root filesystem.

## Admin action

1. Store a SecureString at `<SSM_PREFIX>/databricks-sql-mcp-token`.
2. Review `.devcontainer/policies/tavily-allowed-domains.json` before build.
3. Populate/resolve `.build.env` including `MCP_REMOTE_VERSION=0.1.38` and existing supply-chain checksums/commit pins.
4. Rebuild/re-export (POC) or rebuild/push (Production) and recreate the Developer container.
