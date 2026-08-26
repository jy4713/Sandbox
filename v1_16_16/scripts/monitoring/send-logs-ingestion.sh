#!/usr/bin/env bash
# =============================================================================
# PACKAGE MAINTENANCE NOTES
# Purpose: Linux-host Azure Monitor Logs Ingestion API sender (Option 3).
# =============================================================================
set -euo pipefail
LOG_ROOT="${SANDBOX_LOG_ROOT:-/var/log/ai-sandbox}"; : "${AZURE_MONITOR_ENDPOINT:?Set AZURE_MONITOR_ENDPOINT}"; : "${AZURE_DCR_IMMUTABLE_ID:?Set AZURE_DCR_IMMUTABLE_ID}"; : "${AZURE_TENANT_ID:?Set AZURE_TENANT_ID}"; : "${AZURE_CLIENT_ID:?Set AZURE_CLIENT_ID}"; : "${AZURE_CLIENT_SECRET:?Set AZURE_CLIENT_SECRET}"; STREAM="${AZURE_DCR_STREAM_NAME:-Custom-AISandboxHostLogs}"; STATE="${AZURE_LOG_STATE_FILE:-$LOG_ROOT/.logs-ingestion-state.json}"
TOKEN="$(curl -fsS -X POST "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token" -H 'Content-Type: application/x-www-form-urlencoded' --data-urlencode "client_id=$AZURE_CLIENT_ID" --data-urlencode 'scope=https://monitor.azure.com/.default' --data-urlencode "client_secret=$AZURE_CLIENT_SECRET" --data-urlencode 'grant_type=client_credentials'|python3 -c 'import json,sys;print(json.load(sys.stdin)["access_token"])')"
python3 - "$LOG_ROOT" "$STATE" "$AZURE_MONITOR_ENDPOINT" "$AZURE_DCR_IMMUTABLE_ID" "$STREAM" "$TOKEN" <<'PY2'
import os,sys,json,urllib.request,datetime
root,state_path,endpoint,dcr,stream,token=sys.argv[1:]
try: state=json.load(open(state_path))
except: state={}
for base,_,files in os.walk(root):
 for name in files:
  if not name.endswith('.log'): continue
  p=os.path.join(base,name); lines=open(p,errors='replace').read().splitlines(); start=min(int(state.get(p,0)),len(lines)); records=[{'Time':datetime.datetime.now(datetime.timezone.utc).isoformat(),'RawData':x} for x in lines[start:] if x.strip()]
  for i in range(0,len(records),200):
   body=json.dumps(records[i:i+200]).encode(); req=urllib.request.Request(endpoint.rstrip('/')+f'/dataCollectionRules/{dcr}/streams/{stream}?api-version=2023-01-01',data=body,method='POST',headers={'Authorization':'Bearer '+token,'Content-Type':'application/json'}); urllib.request.urlopen(req,timeout=30).read()
  state[p]=len(lines)
json.dump(state,open(state_path,'w'))
PY2
echo '[OK] Host logs sent to Azure Monitor Logs Ingestion API.'
