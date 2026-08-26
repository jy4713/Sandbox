# Sentinel Integration Assets

The Sandbox does not run a Sentinel-forwarding container.

Use the host-exported files under the configured `SANDBOX_LOG_ROOT` and select one of the supported integration patterns.

## Option 2 - Azure Monitor Agent

Reference DCR body:

```text
dcr-ama-custom-text.example.json
```

Replace all placeholder values and configure the DCR association/agent lifecycle using the customer's approved Azure/endpoint management process.

## Option 3 - Logs Ingestion API

Reference DCR body:

```text
dcr-logs-ingestion.example.json
```

The input stream is:

```text
Custom-AISandboxHostLogs
```

The target custom table is:

```text
AISandboxHostLogs_CL
```

Reference sender scripts are under `scripts/monitoring/`.

## Detection Examples

`detection-rules.kql` contains example queries against `AISandboxHostLogs_CL`.

## v1.16.16 Application Audit Files

The DevContainer host log directory can additionally contain JSON Lines files for:

```text
databricks-events.log
tavily-events.log
snyk-events.log
ado-events.log
git-events.log
hiddenlayer-events.log
mcp-events.log
```

The provided AMA file pattern already uses `devcontainer\*.log`, and the Logs Ingestion API reference sender recursively reads `*.log`, so these files are included without adding a new forwarding component.

The records are metadata-only and are intended for correlation/alerting rather than storage of prompts, responses, scan findings, source code, search queries, credentials, or MCP payloads.
