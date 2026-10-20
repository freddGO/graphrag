#!/usr/bin/env bash
# Print console logs from Log Analytics (no az extensions needed).
#   ./scripts/logs.sh                     # latest indexer job execution
#   ./scripts/logs.sh caj-graphrag-index-abc123
#   ./scripts/logs.sh api                 # API container, last hour
# Logs reach Log Analytics a few minutes after they're written.
set -euo pipefail
cd "$(dirname "$0")/.."
export MSYS_NO_PATHCONV=1

RG="${RG:-rg-graphrag}"
WS="$(az monitor log-analytics workspace list -g "$RG" --query '[0].customerId' -o tsv)"

case "${1:-}" in
  api) FILTER='ContainerAppName_s == "ca-graphrag-api" and TimeGenerated > ago(1h)' ;;
  "")  EXEC="$(az resource list -g "$RG" --resource-type Microsoft.App/jobs --query '[0].name' -o tsv)"
       FILTER="ContainerGroupName_s startswith \"$EXEC-\" and TimeGenerated > ago(1d)" ;;
  *)   FILTER="ContainerGroupName_s startswith \"$1\"" ;;
esac

QUERY="ContainerAppConsoleLogs_CL | where $FILTER | order by TimeGenerated asc | project TimeGenerated, ContainerGroupName_s, Log_s"
BODY="$(python -c 'import json,sys; print(json.dumps({"query": sys.argv[1]}))' "$QUERY")"

az rest --method post --url "https://api.loganalytics.io/v1/workspaces/$WS/query" \
  --resource "https://api.loganalytics.io" --body "$BODY" -o json 2>/dev/null \
| python -c '
import json, re, sys
rows = json.load(sys.stdin)["tables"][0]["rows"]
for time, group, line in rows:
    line = re.sub(r"\x1b\[[0-9;]*m", "", line or "").rstrip()
    if line.strip():
        print(f"{time[11:19]} {group[-12:]}  {line}")
'
