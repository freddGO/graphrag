#!/usr/bin/env bash
# Run the indexer job, wait for it, then tell the API to load the new index.
set -euo pipefail
cd "$(dirname "$0")/.."

RG="${RG:-rg-graphrag}"
# shellcheck disable=SC1091
. ./.deploy.env

output() { az deployment group show -g "$RG" -n main --query "properties.outputs.$1.value" -o tsv; }
JOB="$(output jobName)"
API_URL="$(output apiUrl)"

EXECUTION="$(az containerapp job start -g "$RG" -n "$JOB" --query name -o tsv)"
echo "started $EXECUTION (logs: ./scripts/logs.sh $EXECUTION)"

while :; do
  STATUS="$(az containerapp job execution show -g "$RG" -n "$JOB" --job-execution-name "$EXECUTION" --query properties.status -o tsv)"
  case "$STATUS" in
    Succeeded) echo "indexing succeeded"; break ;;
    Failed|Stopped|Degraded) echo "indexing $STATUS"; exit 1 ;;
    *) echo "  $(date +%H:%M:%S) $STATUS"; sleep 30 ;;
  esac
done

curl -fsS -X POST "$API_URL/reload" -H "X-API-Key: $API_KEY"
echo
